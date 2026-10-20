import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:url_launcher/url_launcher.dart';

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
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00A86B),
        ),
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
  final FlutterTts _tts = FlutterTts();

  static const LatLng _baghdad =
      LatLng(33.3152, 44.3661);

  static const String _userAgent =
      'DaleelIraq/1.0';

  LatLng _center = _baghdad;
  LatLng? _myLocation;
  LatLng? _destination;

  List<LatLng> _routePoints = [];
  List<Map<String, dynamic>> _results = [];

  bool _mapReady = false;
  bool _locating = false;
  bool _searching = false;
  bool _routing = false;
  bool _navigating = false;

  String _status = 'أهلاً بك في دليل العراق 🇮🇶';
  String _destinationName = '';

  double? _distanceKm;
  double? _durationMin;

  @override
  void initState() {
    super.initState();
    _setupVoice();
  }

  Future<void> _setupVoice() async {
    try {
      await _tts.setLanguage('ar');
      await _tts.setSpeechRate(0.45);
      await _tts.setVolume(1.0);
    } catch (_) {
      // يعتمد توفر الصوت العربي على أصوات الهاتف المثبتة.
    }
  }

  void _setStatus(String message) {
    if (!mounted) return;
    setState(() => _status = message);
  }

  bool _isInsideIraq(double lat, double lon) {
    return lat >= 29.0 &&
        lat <= 38.7 &&
        lon >= 38.5 &&
        lon <= 48.8;
  }

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

      var permission = await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied) {
        _setStatus('اسمح للتطبيق باستخدام موقعك');
        return;
      }

      if (permission == LocationPermission.deniedForever) {
        _setStatus('افتح إعدادات التطبيق وفعّل الموقع');
        await Geolocator.openAppSettings();
        return;
      }

      final position = await Geolocator.getCurrentPosition(
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
      _setStatus('تأخر GPS. جرّب في مكان مفتوح');
    } catch (_) {
      _setStatus('تعذر تحديد الموقع. تحقق من الأذونات والإنترنت');
    } finally {
      if (mounted) {
        setState(() => _locating = false);
      }
    }
  }

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
        _setStatus('خدمة البحث غير متاحة حالياً');
        return;
      }

      final data = jsonDecode(response.body) as List<dynamic>;
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
            ? 'ما لكيت نتائج. جرّب اسماً آخر'
            : 'تم العثور على ${found.length} نتيجة';
      });

      if (found.isNotEmpty) {
        _selectPlace(found.first);
      }
    } on TimeoutException {
      _setStatus('انتهت مهلة البحث. تحقق من الإنترنت');
    } catch (_) {
      _setStatus('تعذر الاتصال بخدمة البحث');
    } finally {
      if (mounted) {
        setState(() => _searching = false);
      }
    }
  }

  void _selectPlace(
    Map<String, dynamic> place, {
    bool moveMap = true,
  }) {
    final lat = double.tryParse(
      place['lat']?.toString() ?? '',
    );
    final lon = double.tryParse(
      place['lon']?.toString() ?? '',
    );

    if (lat == null || lon == null) return;

    final point = LatLng(lat, lon);
    final name = place['display_name']?.toString() ?? 'الوجهة';

    setState(() {
      _destination = point;
      _destinationName = name;
      _routePoints = [];
      _distanceKm = null;
      _durationMin = null;
      _results = [];
      _status = 'تم اختيار الوجهة';
    });

    if (moveMap && _mapReady) {
      _mapController.move(point, 15);
    }

    _searchController.text =
        name.split(',').take(2).join(',').trim();
  }

  Future<void> _buildRoute() async {
    if (_destination == null) {
      _setStatus('ابحث عن وجهتك أولاً');
      return;
    }

    if (_myLocation == null) {
      await _goToMyLocation();
    }

    if (_myLocation == null) {
      _setStatus('حدد موقعك أولاً حتى نرسم المسار');
      return;
    }

    setState(() {
      _routing = true;
      _status = 'جارٍ حساب المسار...';
    });

    try {
      final start = _myLocation!;
      final end = _destination!;

      final uri = Uri.parse(
        'https://router.project-osrm.org/route/v1/driving/'
        '${start.longitude},${start.latitude};'
        '${end.longitude},${end.latitude}'
        '?overview=full&geometries=geojson',
      );

      final response = await http.get(
        uri,
        headers: {'User-Agent': _userAgent},
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        _setStatus('تعذر حساب المسار حالياً');
        return;
      }

      final data = jsonDecode(response.body)
          as Map<String, dynamic>;

      final routes = data['routes'] as List<dynamic>?;

      if (routes == null || routes.isEmpty) {
        _setStatus('لم نعثر على مسار بالسيارة لهذه الوجهة');
        return;
      }

      final route = routes.first as Map<String, dynamic>;
      final geometry =
          route['geometry'] as Map<String, dynamic>;
      final coordinates =
          geometry['coordinates'] as List<dynamic>;

      final points = coordinates.map((coordinate) {
        final pair = coordinate as List<dynamic>;
        return LatLng(
          (pair[1] as num).toDouble(),
          (pair[0] as num).toDouble(),
        );
      }).toList();

      if (!mounted) return;

      setState(() {
        _routePoints = points;
        _distanceKm =
            (route['distance'] as num).toDouble() / 1000;
        _durationMin =
            (route['duration'] as num).toDouble() / 60;
        _status = 'تم حساب المسار بنجاح';
      });

      if (_mapReady && points.isNotEmpty) {
        final bounds = LatLngBounds.fromPoints(points);
        _mapController.fitCamera(
          CameraFit.bounds(
            bounds: bounds,
            padding: const EdgeInsets.all(65),
          ),
        );
      }
    } on TimeoutException {
      _setStatus('تأخر حساب المسار. حاول مرة أخرى');
    } catch (_) {
      _setStatus('تعذر حساب المسار. تحقق من الإنترنت');
    } finally {
      if (mounted) {
        setState(() => _routing = false);
      }
    }
  }

  Future<void> _startNavigation() async {
    if (_destination == null) {
      _setStatus('اختار وجهتك من البحث أولاً');
      return;
    }

    if (_myLocation == null) {
      await _goToMyLocation();
    }

    if (_myLocation == null || _destination == null) {
      return;
    }

    final destination = _destination!;

    final uri = Uri.parse(
      'https://www.google.com/maps/dir/?api=1'
      '&origin=${_myLocation!.latitude},${_myLocation!.longitude}'
      '&destination=${destination.latitude},${destination.longitude}'
      '&travelmode=driving',
    );

    try {
      await _tts.speak(
        'تم اختيار الوجهة. جارٍ فتح الملاحة إلى $_destinationName',
      );
    } catch (_) {}

    final opened = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );

    if (!opened) {
      _setStatus('تعذر فتح تطبيق الخرائط على هاتفك');
    }
  }

  Future<void> _speakStatus() async {
    try {
      await _tts.speak(_status);
    } catch (_) {
      _setStatus('تحقق من تثبيت صوت عربي على هاتفك');
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    _tts.stop();
    super.dispose();
  }

  Widget _roundButton({
    required IconData icon,
    required VoidCallback onPressed,
    String? tooltip,
  }) {
    return Material(
      color: Colors.white,
      elevation: 4,
      shape: const CircleBorder(),
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon, color: const Color(0xFF087F5B)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        body: Stack(
          children: [
            Positioned.fill(
              child: FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  initialCenter: _center,
                  initialZoom: 6,
                  onMapReady: () {
                    _mapReady = true;
                  },
                  onTap: (_, point) {
                    setState(() {
                      _center = point;
                    });
                  },
                ),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.daleel.iraq',
                  ),
                  if (_routePoints.isNotEmpty)
                    PolylineLayer(
                      polylines: [
                        Polyline(
                          points: _routePoints,
                          strokeWidth: 6,
                          color: const Color(0xFF087F5B),
                        ),
                      ],
                    ),
                  MarkerLayer(
                    markers: [
                      if (_myLocation != null)
                        Marker(
                          point: _myLocation!,
                          width: 52,
                          height: 52,
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.blue.withValues(alpha: 0.15),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.my_location,
                              color: Colors.blue,
                              size: 32,
                            ),
                          ),
                        ),
                      if (_destination != null)
                        Marker(
                          point: _destination!,
                          width: 48,
                          height: 48,
                          child: const Icon(
                            Icons.location_on,
                            color: Colors.red,
                            size: 44,
                          ),
                        ),
                    ],
                  ),
                  RichAttributionWidget(
                    attributions: [
                      TextSourceAttribution(
                        'OpenStreetMap contributors',
                        onTap: () async {
                          await launchUrl(
                            Uri.parse(
                              'https://www.openstreetmap.org/copyright',
                            ),
                            mode: LaunchMode.externalApplication,
                          );
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // مربع البحث
            Positioned(
              top: MediaQuery.of(context).padding.top + 12,
              left: 14,
              right: 14,
              child: Column(
                children: [
                  Material(
                    elevation: 5,
                    borderRadius: BorderRadius.circular(18),
                    color: Colors.white,
                    child: TextField(
                      controller: _searchController,
                      focusNode: _searchFocus,
                      textInputAction: TextInputAction.search,
                      onSubmitted: _searchPlaces,
                      decoration: InputDecoration(
                        hintText: 'ابحث عن مكان في العراق...',
                        prefixIcon: const Icon(
                          Icons.search,
                          color: Color(0xFF087F5B),
                        ),
                        suffixIcon: _searching
                            ? const Padding(
                                padding: EdgeInsets.all(14),
                                child: SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              )
                            : IconButton(
                                onPressed: _searchPlaces,
                                icon: const Icon(Icons.arrow_forward),
                              ),
                        border: InputBorder.none,
                        contentPadding:
                            const EdgeInsets.symmetric(vertical: 17),
                      ),
                    ),
                  ),

                  if (_results.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(top: 6),
                      constraints:
                          const BoxConstraints(maxHeight: 260),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        boxShadow: const [
                          BoxShadow(
                            blurRadius: 8,
                            color: Colors.black26,
                          ),
                        ],
                      ),
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: _results.length,
                        separatorBuilder: (_, __) =>
                            const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final place = _results[index];
                          final name =
                              place['display_name']?.toString() ??
                                  'مكان بدون اسم';

                          return ListTile(
                            dense: true,
                            leading: const Icon(
                              Icons.place,
                              color: Color(0xFF087F5B),
                            ),
                            title: Text(
                              name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () => _selectPlace(place),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),

            // أزرار الخريطة
            Positioned(
              left: 14,
              bottom: 190,
              child: Column(
                children: [
                  _roundButton(
                    icon: Icons.my_location,
                    tooltip: 'موقعي',
                    onPressed: _goToMyLocation,
                  ),
                  const SizedBox(height: 12),
                  _roundButton(
                    icon: Icons.volume_up,
                    tooltip: 'قراءة الحالة صوتياً',
                    onPressed: _speakStatus,
                  ),
                ],
              ),
            ),

            // لوحة الوجهة والملاحة
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: SafeArea(
                top: false,
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(22),
                    boxShadow: const [
                      BoxShadow(
                        blurRadius: 12,
                        color: Colors.black26,
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.navigation,
                            color: Color(0xFF087F5B),
                            size: 28,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _destination == null
                                  ? 'دليل العراق 🇮🇶'
                                  : _destinationName,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _status,
                        style: const TextStyle(
                          color: Colors.black54,
                          fontSize: 13,
                        ),
                      ),
                      if (_distanceKm != null &&
                          _durationMin != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          'المسافة: ${_distanceKm!.toStringAsFixed(1)} كم'
                          '  •  الوقت التقريبي: '
                          '${_durationMin!.round()} دقيقة',
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: _routing
                                  ? null
                                  : _buildRoute,
                              icon: _routing
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.alt_route),
                              label: const Text('احسب المسار'),
                              style: FilledButton.styleFrom(
                                backgroundColor:
                                    const Color(0xFF087F5B),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: _startNavigation,
                              icon: const Icon(Icons.navigation),
                              label: const Text('ابدأ الملاحة'),
                              style: FilledButton.styleFrom(
                                backgroundColor:
                                    const Color(0xFFEF6C00),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
