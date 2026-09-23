import 'package:geolocator/geolocator.dart';

/// One point at the moment of a handover — never a track of somebody's day.
///
/// It is **captured, never required**: this app is used in basements and back
/// rooms, which is exactly where there is no fix, so a missing one must not
/// stop a pickup or a delivery. Ask for the permission in context (at the first
/// confirm, not at launch) and carry on gracefully when it is refused.
class LocationProbe {
  const LocationProbe();

  Future<Map<String, dynamic>> capture() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return const {};
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return const {};
      }
      final fix = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 8),
        ),
      );
      // Give both coordinates or neither — half a pair is a 422.
      return {
        'latitude': fix.latitude,
        'longitude': fix.longitude,
        'accuracy_m': fix.accuracy,
      };
    } catch (_) {
      return const {};
    }
  }
}
