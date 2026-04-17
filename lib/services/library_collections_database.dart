import 'dart:convert';

import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('LibraryCollectionsDb');

const _dbFileName = 'library_collections.db';
const _dbVersion = 2;

const _tableWishlist = 'wishlist_tracks';
const _tableLoved = 'loved_tracks';
const _tablePlaylists = 'playlists';
const _tablePlaylistTracks = 'playlist_tracks';

const _legacyCollectionsStorageKey = 'library_collections_v1';
const _migrationDoneKey = 'library_collections_migrated_to_sqlite_v1';

class LibraryCollectionsSnapshot {
  final List<Map<String, dynamic>> wishlistRows;
  final List<Map<String, dynamic>> lovedRows;
  final List<Map<String, dynamic>> playlistRows;
  final List<Map<String, dynamic>> playlistTrackRows;

  const LibraryCollectionsSnapshot({
    required this.wishlistRows,
    required this.lovedRows,
    required this.playlistRows,
    required this.playlistTrackRows,
  });
}

class PlaylistPickerSummaryRow {
  final String id;
  final String name;
  final String? coverImagePath;
  final String? previewCover;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int trackCount;
  final bool containsAllRequestedTracks;

  const PlaylistPickerSummaryRow({
    required this.id,
    required this.name,
    this.coverImagePath,
    this.previewCover,
    required this.createdAt,
    required this.updatedAt,
    required this.trackCount,
    required this.containsAllRequestedTracks,
  });
}

class LibraryCollectionsDatabase {
  static final LibraryCollectionsDatabase instance =
      LibraryCollectionsDatabase._init();
  static Database? _database;

  final Future<SharedPreferences> _prefs = SharedPreferences.getInstance();

  LibraryCollectionsDatabase._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDb();
    return _database!;
  }

  Future<Database> _initDb() async {
    final dbPath = await getApplicationDocumentsDirectory();
    final path = join(dbPath.path, _dbFileName);

    _log.i('Initializing collections database at: $path');

    return openDatabase(
      path,
      version: _dbVersion,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
        await db.rawQuery('PRAGMA journal_mode = WAL');
        await db.execute('PRAGMA synchronous = NORMAL');
      },
      onCreate: _createDb,
      onUpgrade: _upgradeDb,
    );
  }

  Future<void> _createDb(Database db, int version) async {
    _log.i('Creating collections database schema v$version');

    await db.execute('''
      CREATE TABLE $_tableWishlist (
        track_key TEXT PRIMARY KEY,
        track_json TEXT NOT NULL,
        added_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE $_tableLoved (
        track_key TEXT PRIMARY KEY,
        track_json TEXT NOT NULL,
        added_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE $_tablePlaylists (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        cover_image_path TEXT,
        sort_order INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE $_tablePlaylistTracks (
        playlist_id TEXT NOT NULL,
        track_key TEXT NOT NULL,
        track_json TEXT NOT NULL,
        sort_order INTEGER NOT NULL DEFAULT 0,
        added_at TEXT NOT NULL,
        PRIMARY KEY (playlist_id, track_key),
        FOREIGN KEY (playlist_id) REFERENCES $_tablePlaylists(id) ON DELETE CASCADE
      )
    ''');

    await db.execute(
      'CREATE INDEX idx_${_tableWishlist}_added_at ON $_tableWishlist(added_at DESC)',
    );
    await db.execute(
      'CREATE INDEX idx_${_tableLoved}_added_at ON $_tableLoved(added_at DESC)',
    );
    await db.execute(
      'CREATE INDEX idx_${_tablePlaylists}_created_at ON $_tablePlaylists(created_at DESC)',
    );
    await db.execute(
      'CREATE INDEX idx_${_tablePlaylists}_sort_order ON $_tablePlaylists(sort_order ASC)',
    );
    await db.execute(
      'CREATE INDEX idx_${_tablePlaylistTracks}_playlist_id ON $_tablePlaylistTracks(playlist_id)',
    );
    await db.execute(
      'CREATE INDEX idx_${_tablePlaylistTracks}_sort_order ON $_tablePlaylistTracks(playlist_id, sort_order ASC)',
    );
    await db.execute(
      'CREATE INDEX idx_${_tablePlaylistTracks}_added_at ON $_tablePlaylistTracks(added_at DESC)',
    );
  }

  Future<void> _upgradeDb(Database db, int oldVersion, int newVersion) async {
    _log.i('Upgrading collections database from v$oldVersion to v$newVersion');
    if (oldVersion < 2) {
      await db.execute(
        'ALTER TABLE $_tablePlaylists ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute(
        'ALTER TABLE $_tablePlaylistTracks ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_${_tablePlaylists}_sort_order ON $_tablePlaylists(sort_order ASC)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_${_tablePlaylistTracks}_sort_order ON $_tablePlaylistTracks(playlist_id, sort_order ASC)',
      );

      final playlistRows = await db.query(
        _tablePlaylists,
        columns: ['id'],
        orderBy: 'created_at DESC, rowid DESC',
      );
      for (var index = 0; index < playlistRows.length; index++) {
        await db.update(
          _tablePlaylists,
          {'sort_order': index},
          where: 'id = ?',
          whereArgs: [playlistRows[index]['id']],
        );
      }

      for (final playlistRow in playlistRows) {
        final playlistId = playlistRow['id'] as String?;
        if (playlistId == null || playlistId.isEmpty) continue;
        final trackRows = await db.query(
          _tablePlaylistTracks,
          columns: ['track_key'],
          where: 'playlist_id = ?',
          whereArgs: [playlistId],
          orderBy: 'added_at DESC, rowid DESC',
        );
        for (var index = 0; index < trackRows.length; index++) {
          await db.update(
            _tablePlaylistTracks,
            {'sort_order': index},
            where: 'playlist_id = ? AND track_key = ?',
            whereArgs: [playlistId, trackRows[index]['track_key']],
          );
        }
      }
    }
  }

  Future<bool> migrateFromSharedPreferences() async {
    final prefs = await _prefs;
    if (prefs.getBool(_migrationDoneKey) == true) {
      return false;
    }

    final raw = prefs.getString(_legacyCollectionsStorageKey);
    if (raw == null || raw.isEmpty) {
      await prefs.setBool(_migrationDoneKey, true);
      return false;
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        await prefs.setBool(_migrationDoneKey, true);
        return false;
      }

      final root = Map<String, dynamic>.from(decoded);
      final wishlistRaw = (root['wishlist'] as List?) ?? const [];
      final lovedRaw = (root['loved'] as List?) ?? const [];
      final playlistsRaw = (root['playlists'] as List?) ?? const [];
      final nowIso = DateTime.now().toIso8601String();

      final db = await database;
      await db.transaction((txn) async {
        for (final entry in wishlistRaw.whereType<Map<Object?, Object?>>()) {
          final map = Map<String, dynamic>.from(entry);
          final trackKey = map['key'] as String?;
          final track = map['track'];
          if (trackKey == null || track is! Map<Object?, Object?>) continue;
          final addedAt = (map['addedAt'] as String?) ?? nowIso;
          await txn.insert(_tableWishlist, {
            'track_key': trackKey,
            'track_json': jsonEncode(track),
            'added_at': addedAt,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }

        for (final entry in lovedRaw.whereType<Map<Object?, Object?>>()) {
          final map = Map<String, dynamic>.from(entry);
          final trackKey = map['key'] as String?;
          final track = map['track'];
          if (trackKey == null || track is! Map<Object?, Object?>) continue;
          final addedAt = (map['addedAt'] as String?) ?? nowIso;
          await txn.insert(_tableLoved, {
            'track_key': trackKey,
            'track_json': jsonEncode(track),
            'added_at': addedAt,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }

        for (final playlistEntry
            in playlistsRaw.whereType<Map<Object?, Object?>>()) {
          final playlist = Map<String, dynamic>.from(playlistEntry);
          final playlistId = playlist['id'] as String?;
          if (playlistId == null || playlistId.isEmpty) continue;

          final createdAt = (playlist['createdAt'] as String?) ?? nowIso;
          final updatedAt = (playlist['updatedAt'] as String?) ?? createdAt;
          await txn.insert(_tablePlaylists, {
            'id': playlistId,
            'name': (playlist['name'] as String?) ?? '',
            'cover_image_path': playlist['coverImagePath'] as String?,
            'created_at': createdAt,
            'updated_at': updatedAt,
          }, conflictAlgorithm: ConflictAlgorithm.replace);

          final tracksRaw = (playlist['tracks'] as List?) ?? const [];
          for (final trackEntry
              in tracksRaw.whereType<Map<Object?, Object?>>()) {
            final trackMap = Map<String, dynamic>.from(trackEntry);
            final trackKey = trackMap['key'] as String?;
            final track = trackMap['track'];
            if (trackKey == null || track is! Map<Object?, Object?>) continue;
            final addedAt = (trackMap['addedAt'] as String?) ?? nowIso;
            await txn.insert(_tablePlaylistTracks, {
              'playlist_id': playlistId,
              'track_key': trackKey,
              'track_json': jsonEncode(track),
              'added_at': addedAt,
            }, conflictAlgorithm: ConflictAlgorithm.replace);
          }
        }
      });

      await prefs.setBool(_migrationDoneKey, true);
      _log.i('Migrated legacy collections data to SQLite');
      return true;
    } catch (e, stack) {
      _log.e('Failed migrating collections to SQLite: $e', e, stack);
      return false;
    }
  }

  Future<LibraryCollectionsSnapshot> loadSnapshot() async {
    final db = await database;
    final wishlistRows = await db.query(
      _tableWishlist,
      orderBy: 'added_at DESC, rowid DESC',
    );
    final lovedRows = await db.query(
      _tableLoved,
      orderBy: 'added_at DESC, rowid DESC',
    );
    final playlistRows = await db.query(
      _tablePlaylists,
      orderBy: 'sort_order ASC, created_at DESC, rowid DESC',
    );
    final playlistTrackRows = await db.query(
      _tablePlaylistTracks,
      orderBy: 'playlist_id ASC, sort_order ASC, added_at DESC, rowid DESC',
    );

    return LibraryCollectionsSnapshot(
      wishlistRows: wishlistRows,
      lovedRows: lovedRows,
      playlistRows: playlistRows,
      playlistTrackRows: playlistTrackRows,
    );
  }

  Future<List<PlaylistPickerSummaryRow>> loadPlaylistPickerSummaries(
    List<String> requestedTrackKeys,
  ) async {
    final db = await database;
    final uniqueTrackKeys = requestedTrackKeys
        .where((key) => key.trim().isNotEmpty)
        .toSet()
        .toList(growable: false);

    final playlistRows = await db.rawQuery('''
      SELECT
        p.id,
        p.name,
        p.cover_image_path,
        p.sort_order,
        p.created_at,
        p.updated_at,
        COUNT(pt.track_key) AS track_count
      FROM $_tablePlaylists p
      LEFT JOIN $_tablePlaylistTracks pt ON pt.playlist_id = p.id
      GROUP BY p.id
      ORDER BY p.sort_order ASC, p.created_at DESC, p.rowid DESC
    ''');

    final matchedCountsByPlaylistId = <String, int>{};
    if (uniqueTrackKeys.isNotEmpty) {
      final placeholders = List.filled(uniqueTrackKeys.length, '?').join(', ');
      final matchedRows = await db.rawQuery('''
          SELECT playlist_id, COUNT(*) AS matched_count
          FROM $_tablePlaylistTracks
          WHERE track_key IN ($placeholders)
          GROUP BY playlist_id
        ''', uniqueTrackKeys);
      for (final row in matchedRows) {
        final playlistId = row['playlist_id']?.toString();
        if (playlistId == null || playlistId.isEmpty) continue;
        matchedCountsByPlaylistId[playlistId] =
            (row['matched_count'] as num?)?.toInt() ?? 0;
      }
    }

    final playlistIdsNeedingPreview = playlistRows
        .where((row) {
          final coverPath = row['cover_image_path']?.toString();
          return coverPath == null || coverPath.isEmpty;
        })
        .map((row) => row['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toList(growable: false);

    final previewCoverByPlaylistId = <String, String?>{};
    if (playlistIdsNeedingPreview.isNotEmpty) {
      final placeholders = List.filled(
        playlistIdsNeedingPreview.length,
        '?',
      ).join(', ');
      final previewRows = await db.rawQuery('''
          SELECT outer_tracks.playlist_id, outer_tracks.track_json
          FROM $_tablePlaylistTracks outer_tracks
          WHERE outer_tracks.playlist_id IN ($placeholders)
            AND outer_tracks.rowid = (
              SELECT inner_tracks.rowid
              FROM $_tablePlaylistTracks inner_tracks
              WHERE inner_tracks.playlist_id = outer_tracks.playlist_id
              ORDER BY inner_tracks.added_at DESC, inner_tracks.rowid DESC
              LIMIT 1
            )
        ''', playlistIdsNeedingPreview);

      for (final row in previewRows) {
        final playlistId = row['playlist_id']?.toString();
        final trackJson = row['track_json'] as String?;
        if (playlistId == null ||
            playlistId.isEmpty ||
            trackJson == null ||
            trackJson.isEmpty) {
          continue;
        }
        try {
          final decoded = jsonDecode(trackJson);
          if (decoded is! Map) continue;
          final coverUrl = decoded['coverUrl']?.toString();
          if (coverUrl != null && coverUrl.isNotEmpty) {
            previewCoverByPlaylistId[playlistId] = coverUrl;
          }
        } catch (_) {}
      }
    }

    return playlistRows
        .map((row) {
          final id = row['id']?.toString() ?? '';
          final createdAt =
              DateTime.tryParse(row['created_at']?.toString() ?? '') ??
              DateTime.now();
          final updatedAt =
              DateTime.tryParse(row['updated_at']?.toString() ?? '') ??
              createdAt;
          return PlaylistPickerSummaryRow(
            id: id,
            name: row['name']?.toString() ?? '',
            coverImagePath: row['cover_image_path'] as String?,
            previewCover: previewCoverByPlaylistId[id],
            createdAt: createdAt,
            updatedAt: updatedAt,
            trackCount: (row['track_count'] as num?)?.toInt() ?? 0,
            containsAllRequestedTracks:
                uniqueTrackKeys.isNotEmpty &&
                matchedCountsByPlaylistId[id] == uniqueTrackKeys.length,
          );
        })
        .toList(growable: false);
  }

  Future<void> upsertWishlistEntry({
    required String trackKey,
    required String trackJson,
    required String addedAt,
  }) async {
    final db = await database;
    await db.insert(_tableWishlist, {
      'track_key': trackKey,
      'track_json': trackJson,
      'added_at': addedAt,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteWishlistEntry(String trackKey) async {
    final db = await database;
    await db.delete(
      _tableWishlist,
      where: 'track_key = ?',
      whereArgs: [trackKey],
    );
  }

  Future<void> upsertLovedEntry({
    required String trackKey,
    required String trackJson,
    required String addedAt,
  }) async {
    final db = await database;
    await db.insert(_tableLoved, {
      'track_key': trackKey,
      'track_json': trackJson,
      'added_at': addedAt,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteLovedEntry(String trackKey) async {
    final db = await database;
    await db.delete(_tableLoved, where: 'track_key = ?', whereArgs: [trackKey]);
  }

  Future<void> upsertPlaylist({
    required String id,
    required String name,
    required String createdAt,
    required String updatedAt,
    required int sortOrder,
    String? coverImagePath,
  }) async {
    final db = await database;
    await db.insert(_tablePlaylists, {
      'id': id,
      'name': name,
      'cover_image_path': coverImagePath,
      'sort_order': sortOrder,
      'created_at': createdAt,
      'updated_at': updatedAt,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> renamePlaylist({
    required String playlistId,
    required String name,
    required String updatedAt,
  }) async {
    final db = await database;
    await db.update(
      _tablePlaylists,
      {'name': name, 'updated_at': updatedAt},
      where: 'id = ?',
      whereArgs: [playlistId],
    );
  }

  Future<void> updatePlaylistCover({
    required String playlistId,
    required String updatedAt,
    String? coverImagePath,
  }) async {
    final db = await database;
    await db.update(
      _tablePlaylists,
      {'cover_image_path': coverImagePath, 'updated_at': updatedAt},
      where: 'id = ?',
      whereArgs: [playlistId],
    );
  }

  Future<void> deletePlaylist(String playlistId) async {
    final db = await database;
    await db.delete(_tablePlaylists, where: 'id = ?', whereArgs: [playlistId]);
  }

  Future<void> upsertPlaylistTrack({
    required String playlistId,
    required String trackKey,
    required String trackJson,
    required int sortOrder,
    required String addedAt,
    required String playlistUpdatedAt,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert(_tablePlaylistTracks, {
        'playlist_id': playlistId,
        'track_key': trackKey,
        'track_json': trackJson,
        'sort_order': sortOrder,
        'added_at': addedAt,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.update(
        _tablePlaylists,
        {'updated_at': playlistUpdatedAt},
        where: 'id = ?',
        whereArgs: [playlistId],
      );
    });
  }

  Future<void> upsertPlaylistTracksBatch({
    required String playlistId,
    required String playlistUpdatedAt,
    required List<Map<String, String>> tracks,
  }) async {
    if (tracks.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final track in tracks) {
        batch.insert(_tablePlaylistTracks, {
          'playlist_id': playlistId,
          'track_key': track['track_key'],
          'track_json': track['track_json'],
          'sort_order': int.tryParse(track['sort_order'] ?? '') ?? 0,
          'added_at': track['added_at'],
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      batch.update(
        _tablePlaylists,
        {'updated_at': playlistUpdatedAt},
        where: 'id = ?',
        whereArgs: [playlistId],
      );
      await batch.commit(noResult: true);
    });
  }

  Future<void> reorderPlaylists({
    required List<String> playlistIdsInOrder,
    required String updatedAt,
  }) async {
    if (playlistIdsInOrder.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (var index = 0; index < playlistIdsInOrder.length; index++) {
        batch.update(
          _tablePlaylists,
          {'sort_order': index, 'updated_at': updatedAt},
          where: 'id = ?',
          whereArgs: [playlistIdsInOrder[index]],
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> reorderPlaylistTracks({
    required String playlistId,
    required List<String> trackKeysInOrder,
    required String playlistUpdatedAt,
  }) async {
    if (trackKeysInOrder.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (var index = 0; index < trackKeysInOrder.length; index++) {
        batch.update(
          _tablePlaylistTracks,
          {'sort_order': index},
          where: 'playlist_id = ? AND track_key = ?',
          whereArgs: [playlistId, trackKeysInOrder[index]],
        );
      }
      batch.update(
        _tablePlaylists,
        {'updated_at': playlistUpdatedAt},
        where: 'id = ?',
        whereArgs: [playlistId],
      );
      await batch.commit(noResult: true);
    });
  }

  Future<void> deletePlaylistTrack({
    required String playlistId,
    required String trackKey,
    required String playlistUpdatedAt,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete(
        _tablePlaylistTracks,
        where: 'playlist_id = ? AND track_key = ?',
        whereArgs: [playlistId, trackKey],
      );
      await txn.update(
        _tablePlaylists,
        {'updated_at': playlistUpdatedAt},
        where: 'id = ?',
        whereArgs: [playlistId],
      );
    });
  }
}
