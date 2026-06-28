import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:uuid/uuid.dart';

import 'tables.dart';

part 'database.g.dart';

const _uuid = Uuid();

@DriftDatabase(
  tables: [
    Providers,
    Channels,
    EpgSources,
    EpgChannels,
    EpgProgrammes,
    EpgMappings,
    ChannelGroups,
    FavoriteLists,
    FavoriteListChannels,
    EpgReminders,
    ScheduledRecordings,
    FailoverGroups,
    FailoverGroupChannels,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 5;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.createTable(favoriteLists);
        await m.createTable(favoriteListChannels);
      }
      if (from < 3) {
        await m.createTable(epgReminders);
        await m.createTable(scheduledRecordings);
      }
      if (from < 4) {
        await m.addColumn(epgProgrammes, epgProgrammes.subtitle);
        await m.addColumn(epgProgrammes, epgProgrammes.episodeNum);
      }
      if (from < 5) {
        await m.createTable(failoverGroups);
        await m.createTable(failoverGroupChannels);
      }
    },
    beforeOpen: (details) async {
      // Enable WAL mode for concurrent read/write (prevents UI blocking)
      await customStatement('PRAGMA journal_mode=WAL');
      await customStatement('PRAGMA synchronous=NORMAL');
      // Add indexes for performance if they don't exist
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_channels_provider ON channels(provider_id)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_channels_group ON channels(provider_id, group_title)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_epg_programmes_channel ON epg_programmes(epg_channel_id, start, stop)',
      );
    },
  );

  // --- Provider queries ---

  Future<List<Provider>> getAllProviders() => select(providers).get();

  Future<void> upsertProvider(ProvidersCompanion entry) =>
      into(providers).insertOnConflictUpdate(entry);

  Future<void> deleteProvider(String id) async {
    // Delete channels belonging to this provider first
    await (delete(channels)..where((t) => t.providerId.equals(id))).go();
    // Then delete the provider itself
    await (delete(providers)..where((t) => t.id.equals(id))).go();
  }

  // --- Channel queries ---

  Future<List<Channel>> getChannelsForProvider(String providerId) =>
      (select(channels)
            ..where((t) => t.providerId.equals(providerId))
            ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
          .get();

  Future<List<Channel>> getChannelsByIds(Set<String> ids) =>
      (select(channels)..where((t) => t.id.isIn(ids))).get();

  /// Get distinct group names per provider without loading channel objects.
  /// Ordered by first appearance in the M3U (minimum sort_order).
  Future<Map<String, List<String>>> getProviderGroups() async {
    final rows = await customSelect(
      'SELECT provider_id, group_title, MIN(sort_order) as min_order FROM channels '
      'WHERE group_title IS NOT NULL AND group_title != \'\' '
      'GROUP BY provider_id, group_title '
      'ORDER BY provider_id, min_order',
    ).get();
    final result = <String, List<String>>{};
    for (final row in rows) {
      final pid = row.read<String>('provider_id');
      final g = row.read<String>('group_title');
      (result[pid] ??= []).add(g);
    }
    return result;
  }

  /// Get channels for a specific provider and group.
  Future<List<Channel>> getChannelsForProviderGroup(
    String providerId,
    String groupTitle,
  ) =>
      (select(channels)
            ..where(
              (t) =>
                  t.providerId.equals(providerId) &
                  t.groupTitle.equals(groupTitle),
            )
            ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
          .get();

  Future<List<Channel>> getFavoriteChannels() =>
      (select(channels)..where((t) => t.favorite.equals(true))).get();

  Future<void> upsertChannels(List<ChannelsCompanion> entries) async {
    await batch((b) {
      b.insertAllOnConflictUpdate(channels, entries);
    });
  }

  Future<void> updateChannelLogo(String channelId, String logoUrl) =>
      (update(channels)..where((t) => t.id.equals(channelId))).write(
        ChannelsCompanion(tvgLogo: Value(logoUrl)),
      );

  /// Batch-update logos for multiple channels in a single transaction.
  Future<void> updateChannelLogos(Map<String, String> idToLogoUrl) async {
    await batch((b) {
      for (final entry in idToLogoUrl.entries) {
        b.update(
          channels,
          ChannelsCompanion(tvgLogo: Value(entry.value)),
          where: (t) => t.id.equals(entry.key),
        );
      }
    });
  }

  Future<void> renameChannel(
    String channelId,
    String providerId,
    String newName,
  ) => (update(channels)..where((t) => t.id.equals(channelId))).write(
    ChannelsCompanion(name: Value(newName)),
  );

  Future<void> toggleFavorite(String channelId) async {
    final channel = await (select(
      channels,
    )..where((t) => t.id.equals(channelId))).getSingle();
    await (update(channels)..where((t) => t.id.equals(channelId))).write(
      ChannelsCompanion(favorite: Value(!channel.favorite)),
    );
  }

  // --- EPG Source queries ---

  Future<List<EpgSource>> getAllEpgSources() => select(epgSources).get();

  Future<void> upsertEpgSource(EpgSourcesCompanion entry) =>
      into(epgSources).insertOnConflictUpdate(entry);

  // --- EPG Channel queries ---

  Future<List<EpgChannel>> getEpgChannelsForSource(String sourceId) =>
      (select(epgChannels)..where((t) => t.sourceId.equals(sourceId))).get();

  Future<void> upsertEpgChannels(List<EpgChannelsCompanion> entries) async {
    await batch((b) {
      b.insertAllOnConflictUpdate(epgChannels, entries);
    });
  }

  // --- EPG Programme queries ---

  Future<List<EpgProgramme>> getProgrammes({
    required String epgChannelId,
    required DateTime start,
    required DateTime end,
  }) =>
      (select(epgProgrammes)
            ..where(
              (t) =>
                  t.epgChannelId.equals(epgChannelId) &
                  t.start.isBiggerOrEqualValue(start) &
                  t.stop.isSmallerOrEqualValue(end),
            )
            ..orderBy([(t) => OrderingTerm.asc(t.start)]))
          .get();

  /// Get what's on now for a list of EPG channel IDs.
  Future<List<EpgProgramme>> getNowPlaying(List<String> epgChannelIds) {
    final now = DateTime.now();
    return (select(epgProgrammes)..where(
          (t) =>
              t.epgChannelId.isIn(epgChannelIds) &
              t.start.isSmallerOrEqualValue(now) &
              t.stop.isBiggerOrEqualValue(now),
        ))
        .get();
  }

  Future<List<EpgProgramme>> getNowPlayingWindow(
    List<String> epgChannelIds,
    DateTime from,
    DateTime to,
  ) {
    return (select(epgProgrammes)..where(
          (t) =>
              t.epgChannelId.isIn(epgChannelIds) &
              t.start.isSmallerOrEqualValue(to) &
              t.stop.isBiggerOrEqualValue(from),
        ))
        .get();
  }

  Future<void> insertProgrammes(List<EpgProgrammesCompanion> entries) async {
    await batch((b) {
      b.insertAll(epgProgrammes, entries, mode: InsertMode.insertOrReplace);
    });
  }

  Future<void> deleteEpgProgrammesForSource(String sourceId) =>
      (delete(epgProgrammes)..where((t) => t.sourceId.equals(sourceId))).go();

  Future<void> insertEpgProgrammes(List<EpgProgrammesCompanion> entries) async {
    await batch((b) {
      b.insertAll(epgProgrammes, entries);
    });
  }

  Future<void> updateEpgSourceRefreshTime(String id) =>
      (update(epgSources)..where((t) => t.id.equals(id))).write(
        EpgSourcesCompanion(lastRefresh: Value(DateTime.now())),
      );

  Future<void> deleteEpgSource(String id) async {
    await deleteEpgProgrammesForSource(id);
    await (delete(epgChannels)..where((t) => t.sourceId.equals(id))).go();
    await (delete(epgSources)..where((t) => t.id.equals(id))).go();
  }

  Future<List<Channel>> getAllChannels() => select(channels).get();

  /// Delete old programmes to keep DB size manageable.
  Future<void> pruneOldProgrammes({Duration maxAge = const Duration(days: 7)}) {
    final cutoff = DateTime.now().subtract(maxAge);
    return (delete(
      epgProgrammes,
    )..where((t) => t.stop.isSmallerThanValue(cutoff))).go();
  }

  // --- EPG Mapping queries ---

  Future<List<EpgMapping>> getAllMappings() => select(epgMappings).get();

  Future<void> upsertMapping(EpgMappingsCompanion entry) =>
      into(epgMappings).insertOnConflictUpdate(entry);

  Future<void> upsertMappings(List<EpgMappingsCompanion> entries) async {
    await batch((b) {
      b.insertAllOnConflictUpdate(epgMappings, entries);
    });
  }

  Future<void> deleteMapping(String channelId, String providerId) =>
      (delete(epgMappings)..where(
            (t) =>
                t.channelId.equals(channelId) & t.providerId.equals(providerId),
          ))
          .go();

  Future<void> deleteAllMappings() => delete(epgMappings).go();

  /// Get mapping stats.
  Future<Map<String, int>> getMappingStats() async {
    final all = await select(epgMappings).get();
    int mapped = 0, suggested = 0;
    for (final m in all) {
      if (m.source == 'auto' || m.source == 'manual') {
        mapped++;
      } else {
        suggested++;
      }
    }
    return {'mapped': mapped, 'suggested': suggested};
  }

  // --- Favorite List queries ---

  Future<List<FavoriteList>> getAllFavoriteLists() => (select(
    favoriteLists,
  )..orderBy([(t) => OrderingTerm.asc(t.sortOrder)])).get();

  Future<List<Channel>> getChannelsInList(String listId) async {
    final query =
        select(channels).join([
            innerJoin(
              favoriteListChannels,
              favoriteListChannels.channelId.equalsExp(channels.id),
            ),
          ])
          ..where(favoriteListChannels.listId.equals(listId))
          ..orderBy([OrderingTerm.asc(favoriteListChannels.sortOrder)]);
    final rows = await query.get();
    return rows.map((row) => row.readTable(channels)).toList();
  }

  Future<void> addChannelToList(String listId, String channelId) =>
      into(favoriteListChannels).insertOnConflictUpdate(
        FavoriteListChannelsCompanion.insert(
          listId: listId,
          channelId: channelId,
        ),
      );

  Future<void> removeChannelFromList(String listId, String channelId) =>
      (delete(favoriteListChannels)..where(
            (t) => t.listId.equals(listId) & t.channelId.equals(channelId),
          ))
          .go();

  Future<FavoriteList> createFavoriteList(String name) async {
    final id = _uuid.v4();
    final count = await (select(favoriteLists)..limit(1000)).get();
    final entry = FavoriteListsCompanion.insert(
      id: id,
      name: name,
      sortOrder: Value(count.length),
    );
    await into(favoriteLists).insert(entry);
    return (select(favoriteLists)..where((t) => t.id.equals(id))).getSingle();
  }

  Future<void> renameFavoriteList(String id, String name) =>
      (update(favoriteLists)..where((t) => t.id.equals(id))).write(
        FavoriteListsCompanion(name: Value(name)),
      );

  Future<void> deleteFavoriteList(String id) async {
    await (delete(
      favoriteListChannels,
    )..where((t) => t.listId.equals(id))).go();
    await (delete(favoriteLists)..where((t) => t.id.equals(id))).go();
  }

  Future<bool> isChannelInList(String listId, String channelId) async {
    final row =
        await (select(favoriteListChannels)..where(
              (t) => t.listId.equals(listId) & t.channelId.equals(channelId),
            ))
            .getSingleOrNull();
    return row != null;
  }

  Future<List<FavoriteList>> getListsForChannel(String channelId) async {
    final query = select(favoriteLists).join([
      innerJoin(
        favoriteListChannels,
        favoriteListChannels.listId.equalsExp(favoriteLists.id),
      ),
    ])..where(favoriteListChannels.channelId.equals(channelId));
    final rows = await query.get();
    return rows.map((row) => row.readTable(favoriteLists)).toList();
  }

  /// Get all channel IDs that belong to any favorite list.
  Future<Set<String>> getAllFavoritedChannelIds() async {
    final rows = await select(favoriteListChannels).get();
    return rows.map((r) => r.channelId).toSet();
  }

  // --- Reminder queries ---

  Future<void> addReminder(EpgRemindersCompanion entry) =>
      into(epgReminders).insertOnConflictUpdate(entry);

  Future<void> deleteReminder(String id) =>
      (delete(epgReminders)..where((t) => t.id.equals(id))).go();

  Future<List<EpgReminder>> getActiveReminders() =>
      (select(epgReminders)..where((t) => t.fired.equals(false))).get();

  Future<List<EpgReminder>> getRemindersForTimeRange(
    DateTime start,
    DateTime end,
  ) =>
      (select(epgReminders)..where(
            (t) =>
                t.programmeStart.isBiggerOrEqualValue(start) &
                t.programmeStart.isSmallerOrEqualValue(end),
          ))
          .get();

  Future<void> markReminderFired(String id) =>
      (update(epgReminders)..where((t) => t.id.equals(id))).write(
        const EpgRemindersCompanion(fired: Value(true)),
      );

  // --- Scheduled Recording queries ---

  Future<void> addScheduledRecording(ScheduledRecordingsCompanion entry) =>
      into(scheduledRecordings).insertOnConflictUpdate(entry);

  Future<void> deleteScheduledRecording(String id) =>
      (delete(scheduledRecordings)..where((t) => t.id.equals(id))).go();

  Future<List<ScheduledRecording>> getAllScheduledRecordings() =>
      select(scheduledRecordings).get();

  Future<List<ScheduledRecording>> getScheduledRecordingsForTimeRange(
    DateTime start,
    DateTime end,
  ) =>
      (select(scheduledRecordings)..where(
            (t) =>
                t.programmeStart.isBiggerOrEqualValue(start) &
                t.programmeStart.isSmallerOrEqualValue(end),
          ))
          .get();

  Future<void> updateRecordingStatus(String id, String status) =>
      (update(scheduledRecordings)..where((t) => t.id.equals(id))).write(
        ScheduledRecordingsCompanion(status: Value(status)),
      );

  // --- Failover Group queries ---

  Future<List<FailoverGroup>> getAllFailoverGroups() => (select(
    failoverGroups,
  )..orderBy([(t) => OrderingTerm.asc(t.name)])).get();

  Future<FailoverGroup> createFailoverGroup(String name) async {
    final id = await into(
      failoverGroups,
    ).insert(FailoverGroupsCompanion.insert(name: name));
    return (select(failoverGroups)..where((t) => t.id.equals(id))).getSingle();
  }

  Future<void> addChannelsToFailoverGroup(
    int groupId,
    List<String> channelIds,
  ) async {
    await batch((b) {
      for (var i = 0; i < channelIds.length; i++) {
        b.insert(
          failoverGroupChannels,
          FailoverGroupChannelsCompanion.insert(
            groupId: groupId,
            channelId: channelIds[i],
            priority: Value(i),
          ),
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  }

  Future<List<FailoverGroupChannel>> getFailoverGroupMembers(int groupId) =>
      (select(failoverGroupChannels)
            ..where((t) => t.groupId.equals(groupId))
            ..orderBy([(t) => OrderingTerm.asc(t.priority)]))
          .get();

  /// Get all failover group memberships keyed by channel ID for fast lookup.
  Future<Map<String, List<FailoverGroupMembership>>>
  getFailoverGroupIndex() async {
    final groups = await getAllFailoverGroups();
    final members = await select(failoverGroupChannels).get();
    final groupMap = {for (final g in groups) g.id: g};
    final index = <String, List<FailoverGroupMembership>>{};
    for (final m in members) {
      final group = groupMap[m.groupId];
      if (group == null) continue;
      index
          .putIfAbsent(m.channelId, () => [])
          .add(FailoverGroupMembership(group: group, priority: m.priority));
    }
    return index;
  }

  Future<void> deleteFailoverGroup(int groupId) async {
    await (delete(
      failoverGroupChannels,
    )..where((t) => t.groupId.equals(groupId))).go();
    await (delete(failoverGroups)..where((t) => t.id.equals(groupId))).go();
  }

  Future<void> renameFailoverGroup(int groupId, String name) =>
      (update(failoverGroups)..where((t) => t.id.equals(groupId))).write(
        FailoverGroupsCompanion(name: Value(name)),
      );

  Future<void> removeChannelFromFailoverGroup(int groupId, String channelId) =>
      (delete(failoverGroupChannels)..where(
            (t) => t.groupId.equals(groupId) & t.channelId.equals(channelId),
          ))
          .go();
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dir = await getApplicationSupportDirectory();
    final file = File(p.join(dir.path, 'clubtivi', 'clubtivi.db'));
    await file.parent.create(recursive: true);

    // Migrate from old ~/Documents location if the new DB doesn't exist yet.
    if (!await file.exists()) {
      final oldDir = await getApplicationDocumentsDirectory();
      final oldFile = File(p.join(oldDir.path, 'clubtivi', 'clubtivi.db'));
      if (await oldFile.exists()) {
        await oldFile.copy(file.path);
      }
    }

    // Corruption recovery: a restored backup (or an interrupted write) can
    // leave a malformed database that bricks the app — reads return nothing
    // and writes throw "database disk image is malformed". If the existing
    // file fails an integrity check, quarantine it and let drift recreate a
    // fresh database so the app stays usable. Only triggers on a definite
    // corruption signal, so healthy data is never touched.
    if (await file.exists()) {
      await _quarantineIfCorrupt(file);
    }

    return NativeDatabase.createInBackground(file);
  });
}

/// Runs a `PRAGMA quick_check` on [file]. If it reports corruption, the file
/// and its WAL/SHM sidecars are renamed aside (kept for manual rescue) so a
/// clean database can be created in their place.
Future<void> _quarantineIfCorrupt(File file) async {
  bool corrupt;
  try {
    final db = sql.sqlite3.open(file.path);
    try {
      final rows = db.select('PRAGMA quick_check');
      final first = rows.isNotEmpty ? rows.first.values.first : null;
      corrupt = first is! String || first.toLowerCase() != 'ok';
    } on sql.SqliteException {
      // Malformed surfaced during the check itself → definitely corrupt.
      corrupt = true;
    } finally {
      db.dispose();
    }
  } catch (_) {
    // Could not even open the file for checking. This may be a native-library
    // edge case rather than corruption, so don't risk wiping good data — let
    // drift open it normally.
    return;
  }

  if (!corrupt) return;

  final ts = DateTime.now().millisecondsSinceEpoch;
  for (final suffix in const ['', '-wal', '-shm']) {
    final f = File('${file.path}$suffix');
    if (await f.exists()) {
      try {
        await f.rename('${file.path}.corrupt-$ts$suffix');
      } catch (_) {
        // If rename fails (e.g. cross-device), delete so a clean db can open.
        try {
          await f.delete();
        } catch (e) {
          debugPrint('[Database] Could not move or delete corrupt db file '
              '${f.path}: $e');
        }
      }
    }
  }
}

/// Lightweight struct for failover group membership lookups.
class FailoverGroupMembership {
  final FailoverGroup group;
  final int priority;
  const FailoverGroupMembership({required this.group, required this.priority});
}
