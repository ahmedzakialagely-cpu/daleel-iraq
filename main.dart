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
      localizationsDelegates: [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
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

  final FocusNode _searchFocus = FocusNode();

  // بغداد هي نقطة البداية الافتراضية.
  LatLng _center = const LatLng(33.3152, 44.3661);

  LatLng? _myLocation;
  LatLng? _selectedPlace;

  List<LatLng> _routePoints = [];

  List<Map<String, dynamic>> _results = [];

  bool _locating = false;
  bool _searching = false;
  bool _routing = false;
  bool _mapReady = false;

  String _status = 'أهلاً بك في دليل العراق 🇮🇶';

  double? _distanceKm;
  double? _durationMin;

  static const String _userAgent =
      'DaleelIraqFlutterApp/1.0';

  void _setStatus(String message) {
    if (!mounted) return;

    setState(() {
      _status = message;
    });
  }

  // التحقق من أن الإحداثيات داخل العراق تقريبياً.
  bool _isInsideIraq(double lat, double lon) {
    return lat >= 29.0 &&
        lat <= 38.7 &&
        lon >= 38.5 &&
        lon <= 48.8;
  }

  // تحديد موقع المستخدم بواسطة GPS.
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
        _setStatus('فعّل الموقع GPS من إعدادات الهاتف');
        return;
      }

      LocationPermission permission =
          await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied) {
        _setStatus('اسمح للتطبيق بالوصول إلى موقعك');
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
          timeLimit: Duration(seconds: 30),
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

      if (_mapReady) {
        _mapController.move(point, 16);
      }
    } on TimeoutException {
      _setStatus(
        'تأخر تحديد الموقع. فعّل GPS وجرب مكاناً مفتوحاً',
      );
    } catch (e) {
      _setStatus('تعذر تحديد الموقع. تحقق من GPS والأذونات');
    } finally {
      if (mounted) {
        setState(() {
          _locating = false;
        });
      }
    }
  }

  // البحث عن المدن والعناوين باستخدام خدمة Nominatim.
  Future<void> _searchPlaces([String? query]) async {
    final text = (query ?? _searchController.text).trim();

    if (text.isEmpty) {
      _setStatus('اكتب اسم مدينة أو مكان للبحث');
      return;
    }

    FocusScope.of(context).unfocus();

    setState(() {
      _searching = true;
      _results = [];
      _status = 'جارٍ البحث عن $text...';
    });

    try {
      final uri = Uri.https(
        'nominatim.openstreetmap.org',
        '/search',
        {
          'q': '$text, Iraq',
          'format': 'jsonv2',
          'limit': '10',
          'addressdetails': '1',
          'accept-language': 'ar',
          'countrycodes': 'iq',
        },
      );

      final response = await http.get(
        uri,
        headers: {
          'User-Agent': _userAgent,
          'Accept': 'application/json',
        },
      ).timeout(const Duration(seconds: 20));

      if (response.statusCode != 200) {
        _setStatus(
          'تعذر البحث حالياً. حاول مرة أخرى لاحقاً',
        );
        return;
      }

      final List<dynamic> data =
          jsonDecode(response.body) as List<dynamic>;

      final found = <Map<String, dynamic>>[];

      for (final item in data) {
        final place = Map<String, dynamic>.from(item);

        final lat = double.tryParse(
          place['lat']?.toString() ?? '',
        );

        final lon = double.tryParse(
          place['lon']?.toString() ?? '',
        );

        if (lat == null || lon == null) continue;

        if (!_isInsideIraq(lat, lon)) continue;

        found.add(place);
      }

      if (!mounted) return;

      setState(() {
        _results = found;
        _status = found.isEmpty
            ? 'ما لكيت نتائج. جرب اسماً آخر'
            : 'تم العثور على ${found.length} نتيجة';
      });

      if (found.isNotEmpty) {
        _selectPlace(found.first, moveMap: false);
      }
    } on TimeoutException {
      _setStatus('انتهت مهلة البحث. تحقق من الإنترنت');
    } catch (e) {
      _setStatus(
        'تعذر الاتصال بخدمة البحث. تحقق من الإنترنت',
      );
    } finally {
      if (mounted) {
