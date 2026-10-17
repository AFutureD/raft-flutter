import 'briefing/orb_briefing_models.dart';

/// What an item is by: the thing behind it and its newest message. A new
/// message in the same thing is a new key.
String orbItemKey(OrbBriefItem i) => '${i.id}@${i.versionKey}';

/// The driving queue after a live re-brief.
class OrbQueueMerge {
  const OrbQueueMerge(this.items, this.index, this.added);

  /// The queue to show.
  final List<OrbBriefItem> items;

  /// The card to show: the one the person was on, still.
  final int index;

  /// What is new in it (not seen in this driving session).
  final List<OrbBriefItem> added;
}

/// Merges [fresh] (the items that need the person now, most urgent first)
/// into [queue] without moving the card at [index] (== [queue].length when
/// all are through):
///
/// * an item of [queue] stays where it is while [fresh] still holds it (same
///   id and version), and the current card stays whatever [fresh] says;
/// * the rest of [queue] is dropped (it no longer needs the person, or it has
///   a newer version, which comes back as new);
/// * an item of [fresh] whose key is not in [seen] is new: it goes right
///   after the current card, in [fresh]'s order; on 就这些 it becomes the next
///   card.
///
/// [seen] is not changed.
OrbQueueMerge mergeDrivingQueue({
  required List<OrbBriefItem> queue,
  required int index,
  required Set<String> seen,
  required List<OrbBriefItem> fresh,
}) {
  final freshKeys = {for (final i in fresh) orbItemKey(i)};
  final hasCurrent = index >= 0 && index < queue.length;
  final kept = <OrbBriefItem>[];
  var before = 0;
  for (var i = 0; i < queue.length; i++) {
    if (i == index || freshKeys.contains(orbItemKey(queue[i]))) {
      if (i < index) before++;
      kept.add(queue[i]);
    }
  }
  final taken = {for (final i in kept) orbItemKey(i)};
  final added = <OrbBriefItem>[];
  for (final i in fresh) {
    final key = orbItemKey(i);
    if (seen.contains(key) || !taken.add(key)) continue;
    added.add(i);
  }
  final at = hasCurrent ? before + 1 : before;
  return OrbQueueMerge(
    [...kept.take(at), ...added, ...kept.skip(at)],
    before,
    added,
  );
}

/// The queue as a string: equal when the same items are in the same order.
String orbQueueSignature(List<OrbBriefItem> items) =>
    items.map(orbItemKey).join('|');
