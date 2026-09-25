import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../config/env.dart';
import '../config/splash_clock.dart';
import '../models/docs.dart';
import 'api/api_error.dart';
import 'services.dart';

enum SessionStage {
  /// Reading secure storage. Nothing on screen yet.
  booting,

  /// No refresh token. The one screen in the app that needs a connection.
  signedOut,

  /// We have a session; a local PIN stands between the operator and the data.
  locked,

  ready,

  /// An administrator revoked this phone. Local data is gone.
  revoked,
}

class SessionState {
  const SessionState({
    required this.stage,
    this.me,
    this.roles = const [],
    this.error,
    this.busy = false,
    this.mustOfferPin = false,
  });

  final SessionStage stage;
  final MeInfo? me;

  /// A UI hint for drawing navigation before the first network call. **The
  /// server enforces group membership on every route regardless.**
  final List<String> roles;
  final String? error;
  final bool busy;

  /// Set once after a fresh sign-in when no local PIN exists yet.
  final bool mustOfferPin;

  bool get hasPickupDelivery => roles.contains('pickup_delivery');
  bool get hasJobWork => roles.contains('job_work');

  SessionState copyWith({
    SessionStage? stage,
    MeInfo? me,
    List<String>? roles,
    String? error,
    bool? busy,
    bool? mustOfferPin,
    bool clearError = false,
  }) =>
      SessionState(
        stage: stage ?? this.stage,
        me: me ?? this.me,
        roles: roles ?? this.roles,
        error: clearError ? null : (error ?? this.error),
        busy: busy ?? this.busy,
        mustOfferPin: mustOfferPin ?? this.mustOfferPin,
      );
}

class SessionController extends Notifier<SessionState> {
  static const _uuid = Uuid();

  Services get _s => ref.read(servicesProvider);

  @override
  SessionState build() {
    scheduleMicrotask(restore);
    return const SessionState(stage: SessionStage.booting);
  }

  /// Cold start with no network, which is the easiest thing to break by
  /// accident: the app opens, unlocks on the local PIN, renders the cache and
  /// accepts new captures. No splash waits on `/health`, nothing blocks on a
  /// token refresh.
  Future<void> restore() async {
    // Reading secure storage takes a few hundred milliseconds, which is not
    // long enough to read a logo. The wait runs *alongside* the work rather
    // than after it, so the splash costs its own duration and not a millisecond
    // more — and it is measured from the first frame, not from here.
    final held = SplashClock.hold(Env.splashMinimum);

    final roles = await _s.tokens.roles();
    if (!await _s.tokens.hasSession) {
      await held;
      state = const SessionState(stage: SessionStage.signedOut);
      return;
    }
    final locked = await _s.pin.isSet;
    await held;
    state = SessionState(
      stage: locked ? SessionStage.locked : SessionStage.ready,
      roles: roles,
    );
    if (!locked) unawaited(_loadMe());
  }

  Future<void> signIn({required String login, required String password}) async {
    state = state.copyWith(busy: true, clearError: true);
    try {
      await _s.auth.login(login: login, password: password);
      state = SessionState(
        stage: SessionStage.ready,
        roles: await _s.tokens.roles(),
        mustOfferPin: !await _s.pin.isSet,
      );
      await _loadMe();
    } on ApiError catch (e) {
      state = state.copyWith(busy: false, error: e.message);
    }
  }

  Future<void> afterCustomerAuth() async {
    state = SessionState(
      stage: SessionStage.ready,
      roles: await _s.tokens.roles(),
      mustOfferPin: !await _s.pin.isSet,
    );
    await _loadMe();
  }

  Future<bool> unlock(String pin) async {
    if (!await _s.pin.verify(pin)) {
      state = state.copyWith(error: 'That PIN is not right.');
      return false;
    }
    state = state.copyWith(stage: SessionStage.ready, clearError: true);
    unawaited(_loadMe());
    return true;
  }

  Future<void> setPin(String pin) async {
    await _s.pin.set(pin);
    state = state.copyWith(mustOfferPin: false);
  }

  void declinePin() => state = state.copyWith(mustOfferPin: false);

  Future<void> _loadMe() async {
    try {
      final me = await _s.auth.me();
      _s.myUserId = me.id;
      state = state.copyWith(me: me, roles: me.roles, busy: false, clearError: true);
    } on ApiError catch (e) {
      // Offline, or an expired token with no signal. Neither is a logout.
      if (e.isWipe) {
        await handleWipe();
      } else {
        state = state.copyWith(busy: false);
      }
    }
  }

  /// The remote-wipe signal. Anything on that phone is diamond logistics data.
  Future<void> handleWipe() async {
    await _s.wipeEverything();
    state = const SessionState(stage: SessionStage.revoked);
  }

  Future<void> signOut() async {
    await _s.auth.logout();
    await _s.wipeEverything();
    state = const SessionState(stage: SessionStage.signedOut);
  }

  Future<void> backToSignIn() async {
    state = const SessionState(stage: SessionStage.signedOut);
  }

  /// Refresh proactively when the app foregrounds and the access token has
  /// under an hour left. A failure here changes nothing on screen.
  Future<void> refreshIfStale() async {
    final expiry = await _s.tokens.accessExpiry();
    if (expiry == null) return;
    if (expiry.difference(DateTime.now()) > Env.refreshWindow) return;
    try {
      await _s.auth.refresh();
    } on ApiError catch (e) {
      if (e.isWipe) await handleWipe();
    }
  }

  String newIdempotencyKey() => _uuid.v4();
}

final sessionProvider =
    NotifierProvider<SessionController, SessionState>(SessionController.new);
