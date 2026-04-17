import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/l10n/l10n.dart';
import 'package:spotiflac_android/providers/download_queue_provider.dart';
import 'package:spotiflac_android/providers/library_collections_provider.dart';
import 'package:spotiflac_android/providers/local_library_provider.dart';
import 'package:spotiflac_android/providers/settings_provider.dart';
import 'package:spotiflac_android/screens/library_tracks_folder_screen.dart';
import 'package:spotiflac_android/services/cover_cache_manager.dart';
import 'package:spotiflac_android/services/library_database.dart';
import 'package:spotiflac_android/widgets/bottom_sheet_option_tile.dart';
import 'package:spotiflac_android/utils/app_bar_layout.dart';

class LibraryPlaylistsScreen extends ConsumerStatefulWidget {
  const LibraryPlaylistsScreen({super.key});

  @override
  ConsumerState<LibraryPlaylistsScreen> createState() =>
      _LibraryPlaylistsScreenState();
}

class _LibraryPlaylistsScreenState
    extends ConsumerState<LibraryPlaylistsScreen> {
  bool _reorderMode = false;

  @override
  Widget build(BuildContext context) {
    final playlistsState = ref.watch(
      libraryCollectionsProvider.select((state) => state.playlists),
    );
    final historyItems = ref.watch(
      downloadHistoryProvider.select((state) => state.items),
    );
    final localItems = ref.watch(
      localLibraryProvider.select((state) => state.items),
    );
    final downloadedKeys = <String>{
      for (final item in historyItems) _downloadHistoryCollectionKey(item),
    };
    final inLibraryKeys = <String>{
      ...downloadedKeys,
      for (final item in localItems) _localCollectionKey(item),
    };
    final pinnedCollectionIds = ref.watch(
      settingsProvider.select((s) => s.pinnedCollectionIds),
    );
    final pinnedSet = pinnedCollectionIds.toSet();
    final playlists = _reorderMode
        ? playlistsState
        : _sortPlaylistsForDisplay(playlistsState, pinnedSet);
    final colorScheme = Theme.of(context).colorScheme;
    final topPadding = normalizedHeaderTopPadding(context);

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 120 + topPadding,
            collapsedHeight: kToolbarHeight,
            floating: false,
            pinned: true,
            backgroundColor: colorScheme.surface,
            surfaceTintColor: Colors.transparent,
            leading: IconButton(
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              icon: const Icon(Icons.arrow_back),
              onPressed: () => Navigator.pop(context),
            ),
            actions: [
              IconButton(
                tooltip: _reorderMode
                    ? context.l10n.collectionDoneReordering
                    : context.l10n.collectionReorderPlaylists,
                icon: Icon(
                  _reorderMode
                      ? Icons.check_circle_outline_rounded
                      : Icons.reorder_rounded,
                ),
                onPressed: playlistsState.length < 2
                    ? null
                    : () {
                        setState(() => _reorderMode = !_reorderMode);
                      },
              ),
            ],

            flexibleSpace: LayoutBuilder(
              builder: (context, constraints) {
                final maxHeight = 120 + topPadding;
                final minHeight = kToolbarHeight + topPadding;
                final expandRatio =
                    ((constraints.maxHeight - minHeight) /
                            (maxHeight - minHeight))
                        .clamp(0.0, 1.0);
                final leftPadding = 56 - (32 * expandRatio);

                return FlexibleSpaceBar(
                  expandedTitleScale: 1.0,
                  titlePadding: EdgeInsets.only(left: leftPadding, bottom: 16),
                  title: Text(
                    context.l10n.collectionPlaylists,
                    style: TextStyle(
                      fontSize: 20 + (8 * expandRatio),
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurface,
                    ),
                  ),
                );
              },
            ),
          ),
          if (playlists.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.playlist_play,
                        size: 60,
                        color: colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        context.l10n.collectionNoPlaylistsYet,
                        style: Theme.of(context).textTheme.titleMedium,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        context.l10n.collectionNoPlaylistsSubtitle,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else
            _reorderMode
                ? SliverReorderableList(
                    itemCount: playlists.length,
                    onReorder: (oldIndex, newIndex) {
                      ref
                          .read(libraryCollectionsProvider.notifier)
                          .reorderPlaylists(oldIndex, newIndex);
                    },
                    itemBuilder: (context, index) {
                      final playlist = playlists[index];
                      return KeyedSubtree(
                        key: ValueKey('reorder_${playlist.id}'),
                        child: _buildPlaylistTile(
                          context,
                          ref,
                          playlist,
                          isPinned: _isPinnedPlaylist(playlist.id, pinnedSet),
                          trailing: ReorderableDelayedDragStartListener(
                            index: index,
                            child: Icon(
                              Icons.drag_handle_rounded,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                          subtitle: _buildPlaylistSubtitle(
                            context,
                            playlist,
                            inLibraryKeys,
                            downloadedKeys,
                          ),
                          enableNavigation: false,
                        ),
                      );
                    },
                  )
                : SliverList(
                    delegate: SliverChildBuilderDelegate((context, index) {
                      if (index.isOdd) {
                        return const Divider(height: 1);
                      }
                      final playlistIndex = index ~/ 2;
                      final playlist = playlists[playlistIndex];
                      return _buildPlaylistTile(
                        context,
                        ref,
                        playlist,
                        isPinned: _isPinnedPlaylist(playlist.id, pinnedSet),
                        subtitle: _buildPlaylistSubtitle(
                          context,
                          playlist,
                          inLibraryKeys,
                          downloadedKeys,
                        ),
                        onLongPress: () =>
                            _showPlaylistOptionsSheet(context, ref, playlist),
                      );
                    }, childCount: playlists.length * 2 - 1),
                  ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showCreatePlaylistDialog(context, ref),
        icon: const Icon(Icons.add),
        label: Text(context.l10n.collectionCreatePlaylist),
      ),
    );
  }

  String _playlistPinKey(String playlistId) => 'playlist:$playlistId';

  bool _isPinnedPlaylist(String playlistId, Set<String> pinnedIds) {
    return pinnedIds.contains(_playlistPinKey(playlistId));
  }

  List<UserPlaylistCollection> _sortPlaylistsForDisplay(
    List<UserPlaylistCollection> playlists,
    Set<String> pinnedIds,
  ) {
    final sorted = [...playlists];
    sorted.sort((a, b) {
      final aPinned = _isPinnedPlaylist(a.id, pinnedIds);
      final bPinned = _isPinnedPlaylist(b.id, pinnedIds);
      if (aPinned != bPinned) {
        return aPinned ? -1 : 1;
      }
      return a.sortOrder.compareTo(b.sortOrder);
    });
    return sorted;
  }

  String _downloadHistoryCollectionKey(DownloadHistoryItem item) {
    final isrc = item.isrc?.trim();
    if (isrc != null && isrc.isNotEmpty) return 'isrc:${isrc.toUpperCase()}';
    final source = item.service.trim().isNotEmpty
        ? item.service.trim()
        : 'builtin';
    return '$source:${item.id}';
  }

  String _localCollectionKey(LocalLibraryItem item) {
    final isrc = item.isrc?.trim();
    if (isrc != null && isrc.isNotEmpty) return 'isrc:${isrc.toUpperCase()}';
    return 'local:${item.id}';
  }

  String _buildPlaylistSubtitle(
    BuildContext context,
    UserPlaylistCollection playlist,
    Set<String> inLibraryKeys,
    Set<String> downloadedKeys,
  ) {
    final total = playlist.tracks.length;
    if (total == 0) return context.l10n.collectionPlaylistTracks(0);
    var inLibraryCount = 0;
    var downloadedCount = 0;
    for (final entry in playlist.tracks) {
      if (inLibraryKeys.contains(entry.key)) {
        inLibraryCount++;
      }
      if (downloadedKeys.contains(entry.key)) {
        downloadedCount++;
      }
    }
    final missingCount = total - inLibraryCount;
    return '${context.l10n.collectionPlaylistTracks(total)} • '
        '${context.l10n.downloadedAlbumDownloadedCount(downloadedCount)} • '
        '${context.l10n.collectionInLibraryCount(inLibraryCount)} • '
        '${context.l10n.collectionMissingCount(missingCount)}';
  }

  Widget _buildPlaylistTile(
    BuildContext context,
    WidgetRef ref,
    UserPlaylistCollection playlist, {
    required bool isPinned,
    required String subtitle,
    Widget? trailing,
    VoidCallback? onLongPress,
    bool enableNavigation = true,
  }) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: _buildPlaylistThumbnail(context, playlist),
      title: Row(
        children: [
          Expanded(child: Text(playlist.name)),
          if (isPinned)
            Icon(
              Icons.push_pin_rounded,
              size: 16,
              color: Theme.of(context).colorScheme.primary,
            ),
        ],
      ),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: trailing,
      onTap: enableNavigation
          ? () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => LibraryTracksFolderScreen(
                    mode: LibraryTracksFolderMode.playlist,
                    playlistId: playlist.id,
                  ),
                ),
              );
            }
          : null,
      onLongPress: enableNavigation ? onLongPress : null,
    );
  }

  void _showPlaylistOptionsSheet(
    BuildContext context,
    WidgetRef ref,
    UserPlaylistCollection playlist,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final pinnedSet = ref.read(settingsProvider).pinnedCollectionIds.toSet();
    final isPinned = _isPinnedPlaylist(playlist.id, pinnedSet);

    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      backgroundColor: colorScheme.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Column(
              children: [
                const SizedBox(height: 8),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: Row(
                    children: [
                      _buildPlaylistThumbnail(context, playlist),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              playlist.name,
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w600),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              context.l10n.collectionPlaylistTracks(
                                playlist.tracks.length,
                              ),
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            Divider(
              height: 1,
              color: colorScheme.outlineVariant.withValues(alpha: 0.5),
            ),

            BottomSheetOptionTile(
              icon: isPinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
              title: isPinned
                  ? context.l10n.collectionRemoveFromHome
                  : context.l10n.collectionAddToHome,
              onTap: () {
                Navigator.pop(sheetContext);
                ref
                    .read(settingsProvider.notifier)
                    .togglePinnedCollection(_playlistPinKey(playlist.id));
              },
            ),

            BottomSheetOptionTile(
              icon: Icons.edit_outlined,
              title: context.l10n.collectionRenamePlaylist,
              onTap: () {
                Navigator.pop(sheetContext);
                _showRenamePlaylistDialog(
                  context,
                  ref,
                  playlist.id,
                  playlist.name,
                );
              },
            ),

            BottomSheetOptionTile(
              icon: Icons.image_outlined,
              title: context.l10n.collectionPlaylistChangeCover,
              onTap: () {
                Navigator.pop(sheetContext);
                _pickCoverImage(context, ref, playlist.id);
              },
            ),

            BottomSheetOptionTile(
              icon: Icons.delete_outline,
              iconColor: colorScheme.error,
              title: context.l10n.collectionDeletePlaylist,
              onTap: () {
                Navigator.pop(sheetContext);
                _confirmDeletePlaylist(
                  context,
                  ref,
                  playlist.id,
                  playlist.name,
                );
              },
            ),

            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaylistThumbnail(
    BuildContext context,
    UserPlaylistCollection playlist,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    const double size = 48;
    final borderRadius = BorderRadius.circular(8);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cacheWidth = (size * dpr).round().clamp(64, 512);
    final placeholder = _playlistIconFallback(colorScheme, size);

    // Priority: custom cover > first track cover URL > icon fallback
    final customCoverPath = playlist.coverImagePath;
    if (customCoverPath != null && customCoverPath.isNotEmpty) {
      return ClipRRect(
        borderRadius: borderRadius,
        child: Image.file(
          File(customCoverPath),
          width: size,
          height: size,
          fit: BoxFit.cover,
          cacheWidth: cacheWidth,
          gaplessPlayback: true,
          filterQuality: FilterQuality.low,
          frameBuilder: (_, child, frame, wasSynchronouslyLoaded) {
            if (wasSynchronouslyLoaded || frame != null) return child;
            return placeholder;
          },
          errorBuilder: (_, _, _) => placeholder,
        ),
      );
    }

    String? firstCoverUrl;
    for (final entry in playlist.tracks) {
      final coverUrl = entry.track.coverUrl;
      if (coverUrl != null && coverUrl.isNotEmpty) {
        firstCoverUrl = coverUrl;
        break;
      }
    }

    if (firstCoverUrl != null) {
      final isLocalPath =
          !firstCoverUrl.startsWith('http://') &&
          !firstCoverUrl.startsWith('https://');

      if (isLocalPath) {
        return ClipRRect(
          borderRadius: borderRadius,
          child: Image.file(
            File(firstCoverUrl),
            width: size,
            height: size,
            fit: BoxFit.cover,
            cacheWidth: cacheWidth,
            gaplessPlayback: true,
            filterQuality: FilterQuality.low,
            frameBuilder: (_, child, frame, wasSynchronouslyLoaded) {
              if (wasSynchronouslyLoaded || frame != null) return child;
              return placeholder;
            },
            errorBuilder: (_, _, _) => placeholder,
          ),
        );
      }

      return ClipRRect(
        borderRadius: borderRadius,
        child: CachedNetworkImage(
          imageUrl: firstCoverUrl,
          width: size,
          height: size,
          fit: BoxFit.cover,
          memCacheWidth: cacheWidth,
          cacheManager: CoverCacheManager.instance,
          placeholder: (_, _) => placeholder,
          errorWidget: (_, _, _) => placeholder,
        ),
      );
    }

    return placeholder;
  }

  Widget _playlistIconFallback(ColorScheme colorScheme, double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(Icons.queue_music, color: colorScheme.onSurfaceVariant),
    );
  }

  Future<void> _pickCoverImage(
    BuildContext context,
    WidgetRef ref,
    String playlistId,
  ) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return;

    final path = result.files.first.path;
    if (path == null || path.isEmpty) return;

    await ref
        .read(libraryCollectionsProvider.notifier)
        .setPlaylistCover(playlistId, path);
  }

  Future<void> _showCreatePlaylistDialog(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final controller = TextEditingController();
    final formKey = GlobalKey<FormState>();

    final playlistName = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(dialogContext.l10n.collectionCreatePlaylist),
          content: Form(
            key: formKey,
            child: TextFormField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(
                hintText: dialogContext.l10n.collectionPlaylistNameHint,
              ),
              validator: (value) {
                final trimmed = value?.trim() ?? '';
                if (trimmed.isEmpty) {
                  return dialogContext.l10n.collectionPlaylistNameRequired;
                }
                return null;
              },
              onFieldSubmitted: (_) {
                if (formKey.currentState?.validate() != true) return;
                Navigator.of(dialogContext).pop(controller.text.trim());
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(dialogContext.l10n.dialogCancel),
            ),
            FilledButton(
              onPressed: () {
                if (formKey.currentState?.validate() != true) return;
                Navigator.of(dialogContext).pop(controller.text.trim());
              },
              child: Text(dialogContext.l10n.actionCreate),
            ),
          ],
        );
      },
    );

    if (playlistName == null ||
        playlistName.trim().isEmpty ||
        !context.mounted) {
      return;
    }

    await ref
        .read(libraryCollectionsProvider.notifier)
        .createPlaylist(playlistName.trim());

    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.collectionPlaylistCreated)),
    );
  }

  Future<void> _showRenamePlaylistDialog(
    BuildContext context,
    WidgetRef ref,
    String playlistId,
    String currentName,
  ) async {
    final controller = TextEditingController(text: currentName);
    final formKey = GlobalKey<FormState>();

    final nextName = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(dialogContext.l10n.collectionRenamePlaylist),
          content: Form(
            key: formKey,
            child: TextFormField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(
                hintText: dialogContext.l10n.collectionPlaylistNameHint,
              ),
              validator: (value) {
                final trimmed = value?.trim() ?? '';
                if (trimmed.isEmpty) {
                  return dialogContext.l10n.collectionPlaylistNameRequired;
                }
                return null;
              },
              onFieldSubmitted: (_) {
                if (formKey.currentState?.validate() != true) return;
                Navigator.of(dialogContext).pop(controller.text.trim());
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(dialogContext.l10n.dialogCancel),
            ),
            FilledButton(
              onPressed: () {
                if (formKey.currentState?.validate() != true) return;
                Navigator.of(dialogContext).pop(controller.text.trim());
              },
              child: Text(dialogContext.l10n.dialogSave),
            ),
          ],
        );
      },
    );

    if (nextName == null || nextName.trim().isEmpty || !context.mounted) {
      return;
    }

    await ref
        .read(libraryCollectionsProvider.notifier)
        .renamePlaylist(playlistId, nextName.trim());

    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.collectionPlaylistRenamed)),
    );
  }

  Future<void> _confirmDeletePlaylist(
    BuildContext context,
    WidgetRef ref,
    String playlistId,
    String playlistName,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(dialogContext.l10n.collectionDeletePlaylist),
          content: Text(
            dialogContext.l10n.collectionDeletePlaylistMessage(playlistName),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(dialogContext.l10n.dialogCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(dialogContext.l10n.dialogDelete),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !context.mounted) return;

    await ref
        .read(libraryCollectionsProvider.notifier)
        .deletePlaylist(playlistId);

    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.collectionPlaylistDeleted)),
    );
  }
}
