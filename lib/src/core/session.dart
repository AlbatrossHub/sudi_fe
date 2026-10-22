import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../config/env.dart';
import '../config/flavor.dart';
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
    this.mustAskGst = false,
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

  /// Customer flavor: `/auth/me` says `gst_state: missing`, so the GST step
  /// runs before the dashboard.
  final bool mustAskGst;

  bool get hasPickupDelivery => roles.contains('pickup_delivery');
  bool get hasJobWork => roles.contains('job_work');
  bool get hasOffice => roles.contains('office');

  /// The "Jangad for a customer" button. An extra ability, never a tab.
  bool get canPostOnBehalf => roles.contains('jangad_on_behalf');

  SessionState copyWith({
    SessionStage? stage,
    MeInfo? me,
    List<String>? roles,
    String? error,
    bool? busy,
    bool? mustOfferPin,
    bool? mustAskGst,
    bool clearError = false,
  }) =>
      SessionState(
        stage: stage ?? this.stage,
        me: me ?? this.me,
        roles: roles ?? this.roles,
        error: clearError ? null : (error ?? this.error),
        busy: busy ?? this.busy,
        mustOfferPin: mustOfferPin ?? this.mustOfferPin,
        mustAskGst: mustAskGst ?? this.mustAskGst,
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

  static bool _needsGst(MeInfo? me) =>
      !sudiFlavor.isField && me != null && me.gstState == 'missing';

  /// Cold start with no network, which is the easiest thing to break by
  /// accident: the app opens, unlocks on the local PIN, renders the cache and
  /// accepts new captures. No splash waits on `/health`, nothing blocks on a
  /// token refresh.
  ///
  /// Signed in, there is no intro at all: the app goes straight back to the
  /// page and tab it was left on, from what is saved on the phone, and asks the
  /// server behind it. Only a signed-out start holds the landing screen.
  Future<void> restore() async {
    final roles = await _s.tokens.roles();
    if (!await _s.tokens.hasSession) {
      // Long enough to read the mark, measured from the first frame and run
      // alongside nothing -- there is nothing else to do signed out.
      await SplashClock.hold(Env.splashMinimum);
      state = const SessionState(stage: SessionStage.signedOut);
      return;
    }
    final saved = await _s.auth.savedMe();
    if (saved != null) _s.myUserId = saved.id;
    final locked = await _s.pin.isSet;
    state = SessionState(
      stage: locked ? SessionStage.locked : SessionStage.ready,
      me: saved,
      roles: saved?.roles ?? roles,
      mustAskGst: _needsGst(saved),
    );
    if (!locked) unawaited(_loadMe());
  }

  Future<void> signIn({required String login, required String password}) async {
    state = state.copyWith(busy: true, clearError: true);
    try {
      // Another account's saved screens must never show.
      await _s.cache.clear();
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
    await _s.cache.clear();
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

  /// The GST step answered: GSTIN saved, or skipped for now.
  Future<void> gstDone(String gstState) async {
    await _s.auth.rememberGstState(gstState);
    state = state.copyWith(
      me: state.me?.withGstState(gstState),
      mustAskGst: false,
    );
  }

  Future<void> _loadMe() async {
    try {
      final me = await _s.auth.me();
      _s.myUserId = me.id;
      state = state.copyWith(
        me: me,
        roles: me.roles,
        busy: false,
        clearError: true,
        mustAskGst: _needsGst(me),
      );
    } on ApiError catch (e) {
      // Offline, or an expired token with no signal. Neither is a logout.
      if (e.isWipe) {
        await handleWipe();
      } else {
        state = state.copyWith(busy: false);
      }
    }
  }

  /// Ask the server again (pull-to-refresh on a screen that shows the name).
  Future<void> reloadMe() => _loadMe();

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
