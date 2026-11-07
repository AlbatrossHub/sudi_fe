import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';

import '../services.dart';

/// Push notifications, the phone side.
///
/// Signing in registers this handset's Firebase token on its device record
/// (`PATCH /devices/me`, the same housekeeping call that reports the app
/// version); Firebase rotates tokens on its own schedule and the server
/// follows. Signing out deletes the token on the device, which is the whole
/// unsubscribe: a deleted token can receive nothing, and the server clears its
/// copy the first time it tries to send to it.
///
/// Everything here is a courtesy and fails like one. A phone without Google
/// services, a refused permission, a network error - each is a debug line,
/// never a dialog, and never in the way of a pickup or a jangad. The app
/// worked before notifications existed and keeps working when they cannot.
class PushService {
  PushService(this._services, this._messenger);

  final Services _services;
  final GlobalKey<ScaffoldMessengerState> _messenger;
  bool _firebaseReady = false;
  bool _signedIn = false;
  final List<StreamSubscription<dynamic>> _subs = [];

  Future<void> boot() async {
    try {
      // No explicit options: google-services.json carries both apps and the
      // native layer picks the client matching this build's package name.
      await Firebase.initializeApp();
      _firebaseReady = true;
    } catch (error) {
      debugPrint('Push: Firebase unavailable: $error');
      return;
    }
    final messaging = FirebaseMessaging.instance;
    // In the foreground the tray stays quiet, so the app says it itself,
    // quietly, at the foot of whatever screen is up.
    _subs.add(FirebaseMessaging.onMessage.listen(_announce));
    // Token rotation: the server must follow or this phone goes silent.
    _subs.add(messaging.onTokenRefresh.listen((token) {
      if (_signedIn) unawaited(_register(token));
    }));
  }

  void dispose() {
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    _subs.clear();
  }

  Future<void> onSignedIn() async {
    _signedIn = true;
    if (!_firebaseReady) return;
    try {
      // The system dialog, shown once - asked right after sign-in rather than
      // at first launch, so the request arrives with a who-is-asking
      // already established.
      await FirebaseMessaging.instance.requestPermission();
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) await _register(token);
    } catch (error) {
      debugPrint('Push: registration failed: $error');
    }
  }

  Future<void> onSignedOut() async {
    _signedIn = false;
    if (!_firebaseReady) return;
    try {
      await FirebaseMessaging.instance.deleteToken();
    } catch (error) {
      debugPrint('Push: token delete failed: $error');
    }
  }

  Future<void> _register(String token) =>
      _services.auth.reportThisDevice(pushToken: token);

  void _announce(RemoteMessage message) {
    final title = message.notification?.title;
    final body = message.notification?.body;
    final text = [title, body].whereType<String>().join(' — ');
    if (text.isEmpty) return;
    _messenger.currentState?.showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 5)),
    );
  }
}
