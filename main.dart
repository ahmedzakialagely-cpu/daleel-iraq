import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_tts/flutter_tts.dart';

void main() {
  runApp(const DaleelIraqApp());
}

class DaleelIraqApp extends StatefulWidget {
  const DaleelIraqApp({super.key});

  @override
  State<DaleelIraqApp> createState() => _DaleelIraqAppState();
}

class _DaleelIraqAppState extends State<DaleelIraqApp> {
  bool darkMode = false;

  @override
  Widget build(BuildContext context) {
    final brightness = darkMode ? Brightness.dark : Brightness.light;

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'دليل العراق - Waze Style',
      theme: ThemeData(
        useMaterial3: true,
        brightness: brightness,
        fontFamily: 'Roboto',
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF33CC66),
          brightness: brightness,
        ),
        scaffoldBackgroundColor:
            darkMode ? const Color(0xFF181B20) : const Color(0xFFF2F4F7),
      ),
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: NavigationScreen(
          darkMode: darkMode,
          onThemeChanged: () {
            setState(() => darkMode = !darkMode);
          },
        ),
      ),
    );
  }
}

class NavigationScreen extends StatefulWidget {
  final bool darkMode;
  final VoidCallback onThemeChanged;

  const NavigationScreen({
    super.key,
    required this.darkMode,
    required this.onThemeChanged,
  });

  @override
  State<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends State<NavigationScreen> {
  final MapController _mapController = MapController();
  final TextEditingController _searchController = TextEditingController();
  final FlutterTts _tts = FlutterTts();
  final Distance _distance = const Distance();

  LatLng _currentLocation = const LatLng(33.3152, 44.3661); // بغداد افتراضياً
  LatLng? _destination;

  List<LatLng> _routePoints = [];
  List<dynamic> _searchResults = [];
  List<Marker> _userReports = []; // بلاغات الطرق السريعة (حوادث/سيطرات/مطبات)

  StreamSubscription<Position>? _positionSubscription;

  bool _loadingLocation = false;
  bool _searching = false;
  bool _navigating = false;
  bool _followingLocation = true;
  bool _showTrafficLayer = true; // طبقة الازدحامات

  double _heading = 0;
  double _speedKmh = 0;
  double _remainingKm = 0;
  double _remainingMinutes = 0;

  String _statusMessage = 'جاهز للانطلاق!';
  String _destinationName = '';

  // ألوان وايز (Waze Theme Colors)
  Color get _wazeGreen => const Color(0xFF33CC66);
  Color get _wazeBlue => const Color(0xFF0099FF);
  Color get _wazeOrange => const Color(0xFFFF9900);
  Color get _wazeRed => const Color(0xFFFF3333);

  Color get _panelColor =>
      widget.darkMode ? const Color(0xFF242831) : Colors.white;

  Color get _textColor =>
      widget.darkMode ? Colors.white : const Color(0xFF222B36);

  Color get _mutedColor =>
      widget.darkMode ? const Color(0xFFA0AAB5) : const Color(0xFF707E8C);

  @override
  void initState() {
    super.initState();
    _configureVoice();
    _getCurrentLocation();
  }

  Future<void> _configureVoice() async {
    try {
      await _tts.setLanguage('ar');
      await _tts.setSpeechRate(0.48);
      await _tts.setVolume(1.0);
    } catch (_) {}
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _searchController.dispose();
    _tts.stop();
    super.dispose();
  }

  Future<void> _getCurrentLocation() async {
    if (!mounted) return;

    setState(() {
      _loadingLocation = true;
      _statusMessage = 'جارٍ تحديد موقعك عبر الـ GPS...';
    });

    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) {
        _setLocationError('يرجى تفعيل خدمة GPS في الهاتف');
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        _setLocationError('يتطلب التطبيق إذن الوصول للموقع');
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );

      if (!mounted) return;

      _currentLocation = LatLng(position.latitude, position.longitude);
      if (position.heading >= 0) _heading = position.heading;
      _speedKmh = math.max(0, position.speed * 3.6);

      _mapController.move(_currentLocation, 16);

      setState(() {
        _loadingLocation = false;
        _statusMessage = 'تم تحديد موقعك الحالي';
      });
    } catch (_) {
      _setLocationError('تعذر الحصول على الموقع. افحص الاتصال بالشبكة');
    }
  }

  void _setLocationError(String message) {
    if (!mounted) return;
    setState(() {
      _loadingLocation = false;
      _statusMessage = message;
    });
  }

  Future<void> _startTracking() async {
    await _positionSubscription?.cancel();

    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 3,
      ),
    ).listen(
      (position) {
        if (!mounted) return;
        _currentLocation = LatLng(position.latitude, position.longitude);

        if (position.heading >= 0 && position.speed > 0.8) {
          _heading = position.heading;
        }
        _speedKmh = math.max(0, position.speed * 3.6);

        if (_followingLocation) {
          _mapController.move(
            _currentLocation,
            _navigating ? 17.5 : _mapController.camera.zoom,
          );
        }

        if (_navigating) _updateProgress();
        if (mounted) setState(() {});
      },
    );
  }

  // البحث عن الأماكن والخدمات
  Future<void> _searchPlaces(String query) async {
    if (query.trim().isEmpty) {
      _showMessage('يرجى كتابة اسم المكان أو المنطقة');
      return;
    }

    FocusScope.of(context).unfocus();

    setState(() {
      _searching = true;
      _statusMessage = 'جارٍ البحث عن "$query"...';
    });

    try {
      final uri = Uri.https(
        'nominatim.openstreetmap.org',
        '/search',
        {
          'q': query.contains('العراق') ? query : '$query, العراق',
          'format': 'jsonv2',
          'limit': '10',
          'countrycodes': 'iq',
          'accept-language': 'ar',
          'addressdetails': '1',
        },
      );

      final response = await http.get(
        uri,
        headers: {
          'User-Agent': 'DaleelIraq_Waze/2.0',
          'Accept-Language': 'ar',
        },
      ).timeout(const Duration(seconds: 12));

      if (response.statusCode != 200) throw Exception('فشل البحث');

      final results = jsonDecode(response.body) as List;

      if (!mounted) return;

      setState(() {
        _searchResults = results;
        _searching = false;
        _statusMessage = results.isEmpty
            ? 'لم نجد نتائج مطابقة لبحثك'
            : 'اختر الوجهة المطلوبة';
      });

      if (results.isEmpty) {
        _showMessage('لم نجد نتائج. حاول البحث باسم أوضح');
      } else {
        _showSearchResults();
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _statusMessage = 'تعذر الاتصال بخادم البحث';
      });
      _showMessage('فشل البحث. تحقق من شبكة الإنترنت');
    }
  }

  void _showSearchResults() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return Container(
          height: MediaQuery.of(context).size.height * 0.65,
          decoration: BoxDecoration(
            color: _panelColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
          ),
          child: Column(
            children: [
              const SizedBox(height: 12),
              Container(
                width: 45,
                height: 5,
                decoration: BoxDecoration(
                  color: _mutedColor.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(18),
                child: Row(
                  children: [
                    Icon(Icons.near_me_rounded, color: _wazeGreen, size: 26),
                    const SizedBox(width: 10),
                    Text(
                      'نتائج البحث عن أماكن',
                      style: TextStyle(
                        color: _textColor,
                        fontSize: 19,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.separated(
                  itemCount: _searchResults.length,
                  separatorBuilder: (_, __) => Divider(
                    color: _mutedColor.withOpacity(0.12),
                    height: 1,
                  ),
                  itemBuilder: (context, index) {
                    final item = _searchResults[index];
                    final name = (item['name'] ?? item['display_name'] ?? 'مكان بدون اسم').toString();

                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                      leading: CircleAvatar(
                        backgroundColor: _wazeGreen.withOpacity(0.15),
                        child: Icon(Icons.place_rounded, color: _wazeGreen),
                      ),
                      title: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: _textColor, fontWeight: FontWeight.bold),
                      ),
                      subtitle: Text(
                        (item['display_name'] ?? '').toString(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: _mutedColor, fontSize: 12),
                      ),
                      onTap: () {
                        final lat = double.tryParse(item['lat'].toString());
                        final lon = double.tryParse(item['lon'].toString());
                        if (lat == null || lon == null) return;

                        _destination = LatLng(lat, lon);
                        _destinationName = name;
                        _routePoints = [];

                        _mapController.move(_destination!, 15.5);
                        Navigator.pop(sheetContext);
                        setState(() => _statusMessage = 'تم اختيار $_destinationName');
                        _showMessage('تم اختيار $_destinationName');
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // حساب المسار الأسرع وتجنب الازدحامات عبر OSRM
  Future<void> _calculateRoute() async {
    if (_destination == null) {
      _showMessage('يرجى تحديد المكان المراد الذهاب إليه أولاً');
      return;
    }

    setState(() => _statusMessage = 'جارٍ حساب الطريق الأسرع وتحديث الازدحامات...');

    try {
      final start = _currentLocation;
      final end = _destination!;

      final uri = Uri.parse(
        'https://router.project-osrm.org/route/v1/driving/'
        '${start.longitude},${start.latitude};'
        '${end.longitude},${end.latitude}'
        '?overview=full&geometries=geojson&steps=true',
      );

      final response = await http.get(uri).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) throw Exception('خطأ حساب المسار');

      final data = jsonDecode(response.body);
      final routes = data['routes'] as List?;
      if (routes == null || routes.isEmpty) throw Exception('لا يوجد مسار');

      final route = routes.first;
      final coordinates = route['geometry']['coordinates'] as List;

      final points = coordinates.map<LatLng>((point) {
        return LatLng((point[1] as num).toDouble(), (point[0] as num).toDouble());
      }).toList();

      if (!mounted) return;

      setState(() {
        _routePoints = points;
        _remainingKm = (route['distance'] as num).toDouble() / 1000;
        _remainingMinutes = (route['duration'] as num).toDouble() / 60;
        _statusMessage = 'تم رسم المسار الأسرع للوصول';
      });

      if (points.isNotEmpty) {
        _mapController.fitCamera(
          CameraFit.bounds(
            bounds: LatLngBounds.fromPoints(points),
            padding: const EdgeInsets.fromLTRB(50, 180, 50, 270),
          ),
        );
      }
      _showMessage('تم حساب المسار بنجاح!');
    } catch (_) {
      if (!mounted) return;
      setState(() => _statusMessage = 'تعذر حساب المسار');
      _showMessage('تعذر رسم المسار. افحص شبكة الإنترنت');
    }
  }

  Future<void> _startNavigation() async {
    if (_destination == null) {
      _showMessage('حدد وجهتك من البحث أولاً');
      return;
    }
    if (_routePoints.isEmpty) {
      await _calculateRoute();
      if (_routePoints.isEmpty) return;
    }

    setState(() {
      _navigating = true;
      _followingLocation = true;
      _statusMessage = 'الملاحة نشطة نحو $_destinationName';
    });

    await _startTracking();
    try {
      await _tts.speak('بدأت الملاحة. اتجه نحو الطريق المحدد وأتمنى لك رحلة آمنة');
    } catch (_) {}
  }

  Future<void> _stopNavigation() async {
    await _positionSubscription?.cancel();
    _positionSubscription = null;
    try {
      await _tts.stop();
    } catch (_) {}

    if (!mounted) return;
    setState(() {
      _navigating = false;
      _followingLocation = false;
      _statusMessage = 'تم إيقاف الملاحة';
    });
  }

  void _updateProgress() {
    if (_routePoints.isEmpty || _destination == null) return;

    int nearestIndex = 0;
    double nearestDistance = double.infinity;

    for (int i = 0; i < _routePoints.length; i++) {
      final d = _distance.as(LengthUnit.Meter, _currentLocation, _routePoints[i]);
      if (d < nearestDistance) {
        nearestDistance = d;
        nearestIndex = i;
      }
    }

    double remainingMeters = 0;
    for (int i = nearestIndex; i < _routePoints.length - 1; i++) {
      remainingMeters += _distance.as(LengthUnit.Meter, _routePoints[i], _routePoints[i + 1]);
    }

    _remainingKm = remainingMeters / 1000;
    if (_speedKmh > 1) {
      _remainingMinutes = remainingMeters / (_speedKmh / 3.6) / 60;
    }

    if (remainingMeters < 30 && _navigating) {
      _stopNavigation();
      _tts.speak('لقد وصلت إلى وجهتك بنجاح');
    }
  }

  // إضافة بلاغ طريق سريعة مستوحي من Waze
  void _addTrafficReport(String title, IconData icon, Color color) {
    setState(() {
      _userReports.add(
        Marker(
          point: _currentLocation,
          width: 44,
          height: 44,
          child: Container(
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2.5),
              boxShadow: [
                BoxShadow(
                  color: color.withOpacity(0.4),
                  blurRadius: 10,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Icon(icon, color: Colors.white, size: 22),
          ),
        ),
      );
    });
    _showMessage('تم إضافة بلاغ ($title) لمساعدة السائقين!');
  }

  // نافذة إرسال بلاغ على الطريق (Waze Reports)
  void _showReportingSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) {
        return Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: _panelColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: _mutedColor.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              const SizedBox(height: 15),
              Text(
                'إبلاغ عن حالة الطريق (Waze Report)',
                style: TextStyle(
                  color: _textColor,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _reportOption('ازدحام شديد', Icons.traffic_rounded, _wazeOrange, () {
                    Navigator.pop(context);
                    _addTrafficReport('ازدحام مروري', Icons.traffic_rounded, _wazeOrange);
                  }),
                  _reportOption('حادث مروري', Icons.warning_amber_rounded, _wazeRed, () {
                    Navigator.pop(context);
                    _addTrafficReport('حادث', Icons.warning_amber_rounded, _wazeRed);
                  }),
                  _reportOption('سيطرة / شرطة', Icons.local_police_rounded, _wazeBlue, () {
                    Navigator.pop(context);
                    _addTrafficReport('سيطرة', Icons.local_police_rounded, _wazeBlue);
                  }),
                  _reportOption('حفرة / مطبة', Icons.construction_rounded, Colors.amber, () {
                    Navigator.pop(context);
                    _addTrafficReport('أشغال طرائق', Icons.construction_rounded
