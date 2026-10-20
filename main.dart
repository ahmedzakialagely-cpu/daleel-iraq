import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_tts/flutter_tts.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DaleelIraqApp());
}

class DaleelIraqApp extends StatelessWidget {
  const DaleelIraqApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'دليل العراق',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.green,
        ),
      ),
      home: const NavigationScreen(),
    );
  }
}

class NavigationScreen extends StatefulWidget {
  const NavigationScreen({super.key});

  @override
  State<NavigationScreen> createState() =>
      _NavigationScreenState();
}

class _NavigationScreenState extends State<NavigationScreen> {
  final MapController _mapController = MapController();
  final TextEditingController _searchController =
      TextEditingController();
  final FlutterTts _tts = FlutterTts();

  StreamSubscription<Position>? _positionSubscription;

  LatLng _myLocation = const LatLng(33.3152, 44.3661);
  LatLng? _destination;

  String _destinationName = '';
  String _status = 'جارٍ تحديد موقعك...';
  String _instruction = 'ابحث عن وجهتك للبدء';

  bool _hasLocation = false;
  bool _isSearching = false;
  bool _isCalculatingRoute = false;
  bool _isNavigating = false;

  List<LatLng> _routePoints = [];
  List<Map<String, dynamic>> _routeSteps = [];

  int _currentStepIndex = 0;

  double _remainingDistance = 0;
  double _remainingDuration = 0;

  DateTime _lastSpokenAt = DateTime(2000);

  @override
  void initState() {
    super.initState();
    _initializeTts();
    _initializeLocation();
  }

  Future<void> _initializeTts() async {
    try {
      await _tts.setLanguage('ar');
      await _tts.setSpeechRate(0.45);
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

  void _setStatus(String message) {
    if (!mounted) return;

    setState(() {
      _status = message;
    });
  }

  // تحديد موقع المستخدم
  Future<void> _initializeLocation() async {
    try {
      final serviceEnabled =
          await Geolocator.isLocationServiceEnabled();

      if (!serviceEnabled) {
        _setStatus('شغّل GPS من إعدادات الهاتف');
        return;
      }

      LocationPermission permission =
          await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        _setStatus(
          'اسمح للتطبيق بالوصول إلى موقعك من الإعدادات',
        );
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      if (!mounted) return;

      setState(() {
        _myLocation = LatLng(
          position.latitude,
          position.longitude,
        );
        _hasLocation = true;
        _status = 'تم تحديد موقعك';
      });

      _mapController.move(_myLocation, 16);
    } catch (e) {
      _setStatus('خطأ GPS: $e');
    }
  }

  Future<void> _goToMyLocation() async {
    if (!_hasLocation) {
      await _initializeLocation();
    }

    if (!_hasLocation || !mounted) return;

    _mapController.move(_myLocation, 17);
    _setStatus('هذا موقعك الحالي');
  }

  // البحث عن الأماكن داخل العراق
  Future<void> _searchPlaces() async {
    final query = _searchController.text.trim();

    if (query.isEmpty) {
      _setStatus('اكتب اسم المكان الذي تريد البحث عنه');
      return;
    }

    setState(() {
      _isSearching = true;
      _status = 'جارٍ البحث عن $query...';
    });

    try {
      final uri = Uri.https(
        'nominatim.openstreetmap.org',
        '/search',
        {
          'q': '$query, Iraq',
          'format': 'jsonv2',
          'limit': '8',
          'addressdetails': '1',
          'accept-language': 'ar',
          'countrycodes': 'iq',
        },
      );

      final response = await http.get(
        uri,
        headers: {
          'User-Agent': 'DaleelIraqNavigation/1.0',
          'Accept-Language': 'ar',
        },
      ).timeout(const Duration(seconds: 25));

      if (response.statusCode != 200) {
        throw Exception(
          'خدمة البحث أعادت HTTP ${response.statusCode}',
        );
      }

      final results = jsonDecode(response.body) as List<dynamic>;

      if (!mounted) return;

      setState(() {
        _isSearching = false;
      });

      if (results.isEmpty) {
        _setStatus('ما لكيت المكان. جرّب اسم ثاني');
        return;
      }

      _showSearchResults(results);
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _isSearching = false;
        _status = 'فشل البحث: $e';
      });
    }
  }

  void _showSearchResults(List<dynamic> results) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.65,
            child: Column(
              children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'نتائج البحث',
                    style: TextStyle(
                      fontSize: 21,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: results.length,
                    itemBuilder: (context, index) {
                      final item =
                          results[index] as Map<String, dynamic>;

                      final name =
                          item['display_name']?.toString() ??
                              'مكان بدون اسم';

                      return ListTile(
                        leading: const Icon(
                          Icons.location_on,
                          color: Colors.green,
                        ),
                        title: Text(
                          name,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () {
                          Navigator.pop(context);
                          _selectDestination(item);
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _selectDestination(
    Map<String, dynamic> item,
  ) async {
    try {
      final latitude = double.parse(item['lat'].toString());
      final longitude = double.parse(item['lon'].toString());

      setState(() {
        _destination = LatLng(latitude, longitude);
        _destinationName =
            item['display_name']?.toString() ?? 'الوجهة';
        _routePoints = [];
        _routeSteps = [];
        _instruction = 'اضغط حساب الطريق';
        _status = 'تم اختيار الوجهة';
      });

      _mapController.move(
        LatLng(latitude, longitude),
        15,
      );

      await _calculateRoute();
    } catch (e) {
      _setStatus('تعذر تحديد الوجهة: $e');
    }
  }

  // حساب الطريق
  Future<void> _calculateRoute() async {
    if (_destination == null) {
      _setStatus('اختار وجهتك أولاً');
      return;
    }

    if (!_hasLocation) {
      await _initializeLocation();
    }

    if (!_hasLocation || _destination == null) {
      _setStatus('تعذر تحديد موقعك الحالي');
      return;
    }

    setState(() {
      _isCalculatingRoute = true;
      _status = 'جارٍ حساب الطريق...';
    });

    try {
      // تكوين الرابط مباشرة لتجنب مشاكل تركيب الرابط
      final uri = Uri.parse(
        'https://router.project-osrm.org/route/v1/driving/'
        '${_myLocation.longitude},${_myLocation.latitude};'
        '${_destination!.longitude},${_destination!.latitude}'
        '?overview=full&geometries=geojson&steps=true',
      );

      final response = await http.get(
        uri,
        headers: {
          'User-Agent': 'DaleelIraqNavigation/1.0',
          'Accept': 'application/json',
        },
      ).timeout(const Duration(seconds: 35));

      if (response.statusCode != 200) {
        throw Exception(
          'خدمة الطرق أعادت HTTP ${response.statusCode}',
        );
      }

      final data =
          jsonDecode(response.body) as Map<String, dynamic>;

      if (data['code'] != 'Ok') {
        throw Exception(
          'خدمة الطرق: ${data['code']}',
        );
      }

      final routes = data['routes'] as List<dynamic>;

      if (routes.isEmpty) {
        throw Exception('لم يتم العثور على طريق');
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

      final legs = route['legs'] as List<dynamic>;

      if (legs.isEmpty) {
        throw Exception('لا توجد تفاصيل للطريق');
      }

      final leg = legs.first as Map<String, dynamic>;

      final rawSteps = leg['steps'] as List<dynamic>? ?? [];

      final steps = rawSteps
          .whereType<Map<String, dynamic>>()
          .toList();

      if (points.isEmpty) {
        throw Exception('المسار الذي وصلنا فارغ');
      }

      if (!mounted) return;

      setState(() {
        _routePoints = points;
        _routeSteps = steps;
        _currentStepIndex = 0;

        _remainingDistance =
            (route['distance'] as num).toDouble();

        _remainingDuration =
            (route['duration'] as num).toDouble();

        _isCalculatingRoute = false;
        _status = 'تم حساب الطريق بنجاح';
        _instruction = 'الطريق جاهز. اضغط بدء الملاحة';
      });

      _fitRouteOnMap();
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _isCalculatingRoute = false;
        // إظهار الخطأ الحقيقي بدل رسالة عامة
        _status = 'خطأ حساب الطريق: $e';
      });
    }
  }

  void _fitRouteOnMap() {
    if (_routePoints.isEmpty) return;

    double minLat = _routePoints.first.latitude;
    double maxLat = minLat;
    double minLng = _routePoints.first.longitude;
    double maxLng = minLng;

    for (final point in _routePoints) {
      if (point.latitude < minLat) minLat = point.latitude;
      if (point.latitude > maxLat) maxLat = point.latitude;
      if (point.longitude < minLng) minLng = point.longitude;
      if (point.longitude > maxLng) maxLng = point.longitude;
    }

    final center = LatLng(
      (minLat + maxLat) / 2,
      (minLng + maxLng) / 2,
    );

    final latDiff = maxLat - minLat;
    final lngDiff = maxLng - minLng;
    final largestDiff =
        latDiff > lngDiff ? latDiff : lngDiff;

    double zoom = 15;

    if (largestDiff > 2) {
      zoom = 6;
    } else if (largestDiff > 1) {
      zoom = 7;
    } else if (largestDiff > 0.5) {
      zoom = 8;
    } else if (largestDiff > 0.2) {
      zoom = 10;
    } else if (largestDiff > 0.08) {
      zoom = 11;
    } else if (largestDiff > 0.03) {
      zoom = 12;
    } else if (largestDiff > 0.01) {
      zoom = 13;
    }

    _mapController.move(center, zoom);
  }

  // بدء الملاحة داخل التطبيق
  Future<void> _startNavigation() async {
    if (_destination == null) {
      _setStatus('اختار وجهتك من البحث أولاً');
      return;
    }

    if (_routePoints.isEmpty) {
      await _calculateRoute();
    }

    if (!mounted) return;

    if (_routePoints.isEmpty) {
      _setStatus('تعذر تجهيز الطريق. راجع رسالة الخطأ أعلاه');
      return;
    }

    if (!_hasLocation) {
      await _initializeLocation();
    }

    if (!_hasLocation || !mounted) {
      _setStatus('تعذر تحديد موقعك');
      return;
    }

    await _positionSubscription?.cancel();

    setState(() {
      _isNavigating = true;
      _status = 'الملاحة بدأت';
    });

    await _speakInstruction(
      'بدأت الملاحة إلى $_destinationName',
    );

    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 5,
      ),
    ).listen(
      (Position position) {
        if (!mounted) return;

        setState(() {
          _myLocation = LatLng(
            position.latitude,
            position.longitude,
          );
        });

        if (_isNavigating) {
          _mapController.move(_myLocation, 17);
          _updateNavigationProgress();
        }
      },
      onError: (error) {
        _setStatus('خطأ متابعة GPS: $error');
      },
    );

    await _updateNavigationProgress();
  }

  Future<void> _updateNavigationProgress() async {
    if (!_isNavigating ||
        _routeSteps.isEmpty ||
        _destination == null) {
      return;
    }

    const distanceCalculator = Distance();

    final distanceToDestination = distanceCalculator(
      _myLocation,
      _destination!,
    );

    if (distanceToDestination < 25) {
      if (!mounted) return;

      setState(() {
        _instruction = 'وصلت إلى وجهتك';
        _status = 'تم الوصول';
        _isNavigating = false;
      });

      await _positionSubscription?.cancel();
      await _speakInstruction('لقد وصلت إلى وجهتك');
      return;
    }

    int closestPointIndex = 0;
    double closestDistance = double.infinity;

    for (int i = 0; i < _routePoints.length; i++) {
      final distance = distanceCalculator(
        _myLocation,
        _routePoints[i],
      );

      if (distance < closestDistance) {
        closestDistance = distance;
        closestPointIndex = i;
      }
    }

    double remainingMeters = 0;

    for (
      int i = closestPointIndex;
      i < _routePoints.length - 1;
      i++
    ) {
      remainingMeters += distanceCalculator(
        _routePoints[i],
        _routePoints[i + 1],
      );
    }

    if (!mounted) return;

    setState(() {
      _remainingDistance = remainingMeters;
      _remainingDuration = remainingMeters / 8.3;
    });

    int bestStep = _currentStepIndex;
    double bestStepDistance = double.infinity;

    for (
      int i = _currentStepIndex;
      i < _routeSteps.length;
      i++
    ) {
      final step = _routeSteps[i];

      final maneuver =
          step['maneuver'] as Map<String, dynamic>?;

      if (maneuver == null) continue;

      final location =
          maneuver['location'] as List<dynamic>?;

      if (location == null || location.length < 2) continue;

      final stepLocation = LatLng(
        (location[1] as num).toDouble(),
        (location[0] as num).toDouble(),
      );

      final distance = distanceCalculator(
        _myLocation,
        stepLocation,
      );

      if (distance < bestStepDistance) {
        bestStepDistance = distance;
        bestStep = i;
      }
    }

    if (bestStepDistance < 40 &&
        bestStep < _routeSteps.length - 1) {
      bestStep++;
    }

    if (bestStep >= _routeSteps.length) {
      bestStep = _routeSteps.length - 1;
    }

    if (bestStep >= 0 && bestStep < _routeSteps.length) {
      final step = _routeSteps[bestStep];

      final maneuver =
          step['maneuver'] as Map<String, dynamic>? ?? {};

      final type = maneuver['type']?.toString() ?? '';
      final modifier =
          maneuver['modifier']?.toString() ?? '';

      final roadName = step['name']?.toString() ?? '';

      final instruction = _arabicInstruction(
        type,
        modifier,
        roadName,
      );

      if (bestStep != _currentStepIndex ||
          _instruction != instruction) {
        if (!mounted) return;

        setState(() {
          _currentStepIndex = bestStep;
          _instruction = instruction;
        });

        await _speakInstruction(instruction);
      }
    }

    if (closestDistance > 80) {
      final now = DateTime.now();

      if (now.difference(_lastSpokenAt).inSeconds > 30) {
        _lastSpokenAt = now;

        await _speakInstruction(
          'انتبه إلى الطريق واتبع المسار الظاهر على الخريطة',
        );
      }
    }
  }

  String _arabicInstruction(
    String type,
    String modifier,
    String roadName,
  ) {
    String action;

    if (type == 'arrive') {
      action = 'اقتربت من وجهتك';
    } else if (type == 'depart') {
      action = 'ابدأ السير';
    } else if (type == 'roundabout' ||
        type == 'rotary') {
      action = 'ادخل إلى الدوار';
    } else if (modifier.contains('left')) {
      action = 'استعد للانعطاف يساراً';
    } else if (modifier.contains('right')) {
      action = 'استعد للانعطاف يميناً';
    } else if (modifier == 'uturn') {
      action = 'استدر إلى الاتجاه المعاكس';
    } else if (type == 'turn') {
      action = 'اتبع اتجاه الطريق';
    } else {
      action = 'واصل السير';
    }

    if (roadName.isNotEmpty) {
      return '$action باتجاه $roadName';
    }

    return action;
  }

  Future<void> _speakInstruction(String text) async {
    try {
      await _tts.stop();
      await _tts.speak(text);
    } catch (_) {}
  }

  Future<void> _stopNavigation() async {
    await _positionSubscription?.cancel();
    _positionSubscription = null;

    await _tts.stop();

    if (!mounted) return;

    setState(() {
      _isNavigating = false;
      _status = 'تم إيقاف الملاحة';
      _instruction = 'ابحث عن وجهتك للبدء';
    });
  }

  String _formatDistance(double meters) {
    if (meters >= 1000) {
      return '${(meters / 1000).toStringAsFixed(1)} كم';
    }

    return '${meters.round()} متر';
  }

  String _formatDuration(double seconds) {
    final minutes = (seconds / 60).ceil();

    if (minutes >= 60) {
      final hours = minutes ~/ 60;
      final remainingMinutes = minutes % 60;

      return '$hours ساعة و$remainingMinutes دقيقة';
    }

    return '$minutes دقيقة';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.green.shade700,
        foregroundColor: Colors.white,
        title: const Row(
          children: [
            Icon(Icons.navigation),
            SizedBox(width: 10),
            Text(
              'دليل العراق',
              style: TextStyle(
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'موقعي',
            onPressed: _goToMyLocation,
            icon: const Icon(Icons.my_location),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _searchPlaces(),
                    decoration: InputDecoration(
                      hintText: 'ابحث عن مكان في العراق',
                      prefixIcon: const Icon(Icons.search),
                      filled: true,
                      fillColor: Colors.grey.shade100,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(15),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: 'بحث',
                  onPressed:
                      _isSearching ? null : _searchPlaces,
                  icon: _isSearching
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                          ),
                        )
                      : const Icon(Icons.search),
                ),
              ],
            ),
          ),

          Expanded(
            child: FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: _myLocation,
                initialZoom: 6,
                onTap: (tapPosition, point) {
                  if (_isNavigating) return;

                  setState(() {
                    _destination = point;
                    _destinationName =
                        'الوجهة المحددة على الخريطة';
                    _routePoints = [];
                    _routeSteps = [];
                    _instruction = 'اضغط حساب الطريق';
                    _status = 'تم اختيار الوجهة';
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
                        strokeWidth: 7,
                        color: Colors.blue,
                      ),
                    ],
                  ),

                MarkerLayer(
                  markers: [
                    if (_hasLocation)
                      Marker(
                        point: _myLocation,
                        width: 50,
                        height: 50,
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.blue,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.white,
                              width: 4,
                            ),
                            boxShadow: const [
                              BoxShadow(
                                color: Colors.black26,
                                blurRadius: 8,
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.navigation,
                            color: Colors.white,
                            size: 25,
                          ),
                        ),
                      ),

                    if (_destination != null)
                      Marker(
                        point: _destination!,
                        width: 45,
                        height: 45,
                        child: const Icon(
                          Icons.location_pin,
                          color: Colors.red,
                          size: 45,
                        ),
                      ),
                  ],
                ),

                RichAttributionWidget(
                  attributions: [
                    TextSourceAttribution(
                      'OpenStreetMap contributors',
                    ),
                  ],
                ),
              ],
            ),
          ),

          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 10,
                  offset: const Offset(0, -3),
                ),
              ],
            ),
            child: SafeArea(
              top: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Icon(
                        _isNavigating
                            ? Icons.navigation
                            : Icons.info_outline,
                        color: Colors.green.shade700,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _status,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14),
                        ),
                      ),
                    ],
                  ),

                  if (_isNavigating) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.green.shade50,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment:
                            CrossAxisAlignment.start,
                        children: [
                          Text(
                            _instruction,
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              const Icon(Icons.route, size: 18),
                              const SizedBox(width: 6),
                              Text(
                                _formatDistance(
                                  _remainingDistance,
                                ),
                              ),
                              const SizedBox(width: 18),
                              const Icon(
                                Icons.access_time,
                                size: 18,
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  _formatDuration(
                                    _remainingDuration,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],

                  const SizedBox(height: 12),

                  if (!_isNavigating)
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _hasLocation
                                ? _goToMyLocation
                                : _initializeLocation,
                            icon: const Icon(Icons.my_location),
                            label: const Text('موقعي'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _destination == null ||
                                    _isCalculatingRoute
                                ? null
                                : _calculateRoute,
                            icon: _isCalculatingRoute
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.route),
                            label: const Text('حساب الطريق'),
                          ),
                        ),
                      ],
                    ),

                  const SizedBox(height: 8),

                  SizedBox(
                    height: 48,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _isNavigating
                            ? Colors.red.shade700
                            : Colors.green.shade700,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: _isNavigating
                          ? _stopNavigation
                          : _startNavigation,
                      icon: Icon(
                        _isNavigating
                            ? Icons.stop
                            : Icons.navigation,
                      ),
                      label: Text(
                        _isNavigating
                            ? 'إيقاف الملاحة'
                            : 'بدء الملاحة',
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
