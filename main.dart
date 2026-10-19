import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(const DaleelApp());
}

class DaleelApp extends StatelessWidget {
  const DaleelApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'دليل العراق',
      locale: const Locale('ar'),
      supportedLocales: const [
        Locale('ar'),
        Locale('en'),
      ],
      localizationsDelegates:
          GlobalMaterialLocalizations.delegates,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF087F5B),
        useMaterial3: true,
      ),
      home: const MapHome(),
    );
  }
}

class MapHome extends StatefulWidget {
  const MapHome({super.key});

  @override
  State<MapHome> createState() => _MapHomeState();
}

class _MapHomeState extends State<MapHome> {
  final MapController _mapController = MapController();

  final TextEditingController _searchController =
      TextEditingController();

  LatLng _center = const LatLng(33.3152, 44.3661);

  LatLng? _myLocation;
  LatLng? _selectedPlace;

  List<LatLng> _routePoints = [];

  List<Map<String, dynamic>> _results = [];

  bool _locating = false;
  bool _searching = false;
  bool _routing = false;

  String _status = 'أهلاً بك في دليل العراق 🇮🇶';

  double? _distanceKm;
  double? _durationMin;

  // تحديث رسالة الحالة
  void _setStatus(String message) {
    if (!mounted) return;

    setState(() {
      _status = message;
    });
  }

  // تحديد الموقع الحقيقي
  Future<void> _goToMyLocation() async {
    if (_locating) return;

    setState(() {
      _locating = true;
      _status = 'جارٍ تحديد موقعك...';
    });

    try {
      final enabled =
          await Geolocator.isLocationServiceEnabled();

      if (!enabled) {
        _setStatus('فعّل GPS من إعدادات الهاتف');
        return;
      }

      LocationPermission permission =
          await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied) {
        _setStatus('اسمح للتطبيق باستخدام موقعك');
        return;
      }

      if (permission == LocationPermission.deniedForever) {
        _setStatus(
          'افتح إعدادات التطبيق واسمح بالوصول للموقع',
        );

        await Geolocator.openAppSettings();
        return;
      }

      final position =
          await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 25),
        ),
      );

      final point = LatLng(
        position.latitude,
        position.longitude,
      );

      if (!mounted) return;

      setState(() {
        _myLocation = point;
        _center = point;
        _status = 'تم تحديد موقعك بنجاح';
      });

      _mapController.move(point, 16);
    } on TimeoutException {
      _setStatus(
        'تأخر تحديد الموقع. جرّب مكاناً مفتوحاً',
      );
    } catch (e) {
      _setStatus('تعذر تحديد الموقع: $e
