import 'package:flutter/foundation.dart';
import 'package:raft_client/raft_client.dart';

/// A thread keeps its parent identity while its channel is being resolved.
typedef ConversationWindowScope = ({String channelId, String? parentMessageId});

/// Why a jump target's message context could not be shown.
enum MessageContextLoadError { notFound, beyondHistory }

/// One read of the existing accepted window. This is a presentation snapshot,
/// not a second message store or a grant to accept a response.
@immutable
class ConversationWindowSnapshot {
  ConversationWindowSnapshot({
    this.channelId,
    List<RaftMessage> rows = const [],
    List<RaftMessage>? timeline,
    this.parent,
    this.loading = false,
    this.loadingOlder = false,
    this.parentLoading = false,
    this.resolving = false,
    this.hasMore = false,
    this.hasNewer = false,
    this.historyLimited = false,
    this.highlightedMessageId,
    this.error,
    this.contextLoadError,
    this.retired = false,
  }) : rows = List.unmodifiable(rows),
       timeline = List.unmodifiable(timeline ?? rows);

  final String? channelId, highlightedMessageId, error;
  final List<RaftMessage> rows, timeline;
  final RaftMessage? parent;
  final bool loading, loadingOlder, parentLoading, resolving;
  final bool hasMore, hasNewer, historyLimited, retired;
  final MessageContextLoadError? contextLoadError;

  /// Ledger and pending rows have stable wrappers for each row version. No
  /// payload encoding or deep comparison is needed on unrelated notifications.
  bool samePresentation(ConversationWindowSnapshot other) =>
      (
            channelId,
            highlightedMessageId,
            error,
            loading,
            loadingOlder,
            parentLoading,
            resolving,
            hasMore,
            hasNewer,
            historyLimited,
            contextLoadError,
            retired,
          ) ==
          (
            other.channelId,
            other.highlightedMessageId,
            other.error,
            other.loading,
            other.loadingOlder,
            other.parentLoading,
            other.resolving,
            other.hasMore,
            other.hasNewer,
            other.historyLimited,
            other.contextLoadError,
            other.retired,
          ) &&
      identical(parent, other.parent) &&
      listEquals(rows, other.rows) &&
      listEquals(timeline, other.timeline);
}

/// Stable, read-only presentation of one channel or parent-message scope.
/// Commands and read receipts remain with the workspace session. The owner
/// retires this reference on authority loss; it never becomes another scope.
abstract class ConversationWindow {
  ConversationWindowScope get scope;
  ConversationWindowSnapshot get snapshot;
  Listenable get changes;

  /// Current layout admission, read without notifying or writing a receipt.
  bool get visible;
  String? get channelId => snapshot.channelId;
  List<RaftMessage> get rows => snapshot.rows;
  List<RaftMessage> get timeline => snapshot.timeline;
  RaftMessage? get parent => snapshot.parent;
  bool get loading => snapshot.loading;
  bool get loadingOlder => snapshot.loadingOlder;
  bool get parentLoading => snapshot.parentLoading;
  bool get resolving => snapshot.resolving;
  bool get hasMore => snapshot.hasMore;
  bool get hasNewer => snapshot.hasNewer;
  bool get historyLimited => snapshot.historyLimited;
  bool get retired => snapshot.retired;
  String? get highlightedMessageId => snapshot.highlightedMessageId;
  String? get error => snapshot.error;
  MessageContextLoadError? get contextLoadError => snapshot.contextLoadError;
}
