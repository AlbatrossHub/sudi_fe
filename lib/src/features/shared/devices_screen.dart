import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/clock/odoo_time.dart';
import '../../core/services.dart';
import '../../models/docs.dart';
import '../../ui/theme/neu.dart';
import '../../ui/widgets/neu_box.dart';
import '../../ui/widgets/neu_widgets.dart';
import '../../ui/widgets/status_strip.dart';

/// `GET /devices` — every handset signed in to this account.
///
/// Shared by both flavors. Per-device revocation is the whole reason devices
/// are records server-side, and until this screen existed there was no way for
/// the person who lost a phone to actually use it.
final devicesProvider = FutureProvider.autoDispose<List<RegisteredDevice>>(
  (ref) => ref.read(servicesProvider).auth.devices(),
);

class DevicesScreen extends ConsumerStatefulWidget {
  const DevicesScreen({super.key});

  @override
  ConsumerState<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends ConsumerState<DevicesScreen> {
  /// null = not checked yet. The status strip reports the *radio*; this
  /// reports whether the office actually answers, which is a different
  /// question and the one support needs answered.
  bool? _reachable;
  bool _checking = false;
  String? _busyUid;

  Future<void> _checkConnection() async {
    setState(() => _checking = true);
    final ok = await ref.read(servicesProvider).auth.health();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _reachable = ok;
    });
  }

  Future<void> _revoke(RegisteredDevice device) async {
    final c = NeuTheme.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: c.ground,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Text('Sign this phone out?', style: NeuText.title(c.ink, size: 20)),
        content: Text(
          '${device.platformLabel} · ${device.shortUid} loses its session at '
          'once. Anything it captured and has not sent yet is lost with it.',
          style: NeuText.body_(c.inkMuted, size: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Keep it', style: NeuText.label(c.inkMuted, size: 13)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Sign it out', style: NeuText.label(c.attentionInk, size: 13)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busyUid = device.deviceUid);
    try {
      await ref.read(servicesProvider).auth.revokeDevice(device.deviceUid);
      ref.invalidate(devicesProvider);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$error')),
        );
      }
    } finally {
      if (mounted) setState(() => _busyUid = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = NeuTheme.of(context);
    final devices = ref.watch(devicesProvider);

    return NeuScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ScreenHeader(
            title: 'Your phones',
            subtitle: 'Signed in to this account',
            onBack: () => context.pop(),
          ),
          const SizedBox(height: 14),
          _connectionRow(context),
          const SizedBox(height: 14),
          Expanded(
            child: RefreshIndicator(
              color: c.accentInk,
              backgroundColor: c.ground,
              onRefresh: () async => ref.invalidate(devicesProvider),
              child: switch (devices) {
                AsyncLoading() => const Center(child: CircularProgressIndicator()),
                AsyncError(:final error) => ListView(
                    children: [
                      const SizedBox(height: 40),
                      NeuNote(
                        title: 'Could not read your phones',
                        text: '$error',
                        icon: Icons.wifi_off_rounded,
                        kind: ChipKind.queued,
                      ),
                    ],
                  ),
                AsyncData(:final value) when value.isEmpty => const EmptyState(
                    message: 'No phones registered',
                    hint: 'Signing in registers the handset you sign in on',
                    icon: Icons.smartphone_outlined,
                  ),
                AsyncData(:final value) => ListView.separated(
                    itemCount: value.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (_, i) => _deviceCard(context, value[i]),
                  ),
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _connectionRow(BuildContext context) {
    final c = NeuTheme.of(context);
    final (label, kind, icon) = switch (_reachable) {
      null => ('Not checked', ChipKind.other, Icons.help_outline_rounded),
      true => ('Office reachable', ChipKind.synced, Icons.check_rounded),
      false => ('No answer', ChipKind.attention, Icons.warning_amber_rounded),
    };

    // One tappable row rather than a button inside a box: a NeuButton is sized
    // for a full-width primary action and spills out of a card this size.
    return NeuBox(
      style: NeuStyle.inset,
      radius: 16,
      padding: const EdgeInsets.fromLTRB(16, 13, 14, 13),
      onTap: _checking ? null : _checkConnection,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Connection to the office',
                    style: NeuText.label(c.inkMuted, size: 12)),
                const SizedBox(height: 6),
                StateChip(
                  _checking ? 'Checking…' : label,
                  kind: _checking ? ChipKind.other : kind,
                  icon: _checking ? Icons.sync_rounded : icon,
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Icon(Icons.refresh_rounded, size: 20, color: c.inkMuted),
        ],
      ),
    );
  }

  Widget _deviceCard(BuildContext context, RegisteredDevice device) {
    final c = NeuTheme.of(context);
    final busy = _busyUid == device.deviceUid;

    return NeuBox(
      style: NeuStyle.raised,
      radius: 20,
      padding: const EdgeInsets.fromLTRB(17, 16, 17, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  device.versionLabel == null
                      ? device.platformLabel
                      : '${device.platformLabel} · ${device.versionLabel}',
                  style: NeuText.strong(c.ink, size: 15),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              if (device.isCurrent)
                const StateChip('This phone', kind: ChipKind.accent)
              else if (device.revoked)
                const StateChip('Signed out', kind: ChipKind.blocked),
            ],
          ),
          const SizedBox(height: 9),
          Text(device.shortUid, style: NeuText.data(c.inkMuted, size: 12)),
          const SizedBox(height: 9),
          Text(
            'Last seen ${OdooTime.ago(device.lastSeenAt)} · '
            'synced to ${device.syncCursor}',
            style: NeuText.body_(c.inkMuted, size: 12.5),
          ),
          if (!device.isCurrent && !device.revoked) ...[
            const SizedBox(height: 14),
            NeuButton(
              label: 'Sign this phone out',
              kind: NeuButtonKind.destructive,
              icon: Icons.logout_rounded,
              height: 46,
              busy: busy,
              onPressed: busy ? null : () => _revoke(device),
            ),
          ],
        ],
      ),
    );
  }
}
