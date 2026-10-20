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
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'دليل العراق',
      theme: ThemeData(
        useMaterial3: true,
        brightness: darkMode ? Brightness.dark : Brightness.light,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00A878),
          brightness: darkMode ? Brightness.dark : Brightness.light,
        ),
        fontFamily: 'Roboto',
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

  LatLng _currentLocation = const LatLng(33.3152, 44.3661);
  LatLng? _destination;

  List<LatLng> _routePoints = [];
  List<dynamic> _searchResults = [];

  StreamSubscription<Position>? _positionSubscription;

  bool _loadingLocation = false;
  bool _searching = false;
  bool _navigating = false;
  bool _showSearch = false;

  double _heading = 0;
  double _remainingKm = 0;
  double _remainingMinutes = 0;
  double _currentSpeed = 0;

  String _statusMessage = 'أهلاً بك في دليل العراق';
  String _destinationName = '';

  Color get _green => const Color(0xFF00A878);

  Color get _panelColor =>
      widget.darkMode ? const Color(0xFF202A33) : Colors.white;

  Color get _textColor =>
      widget.darkMode ? Colors.white : const Color(0xFF17212B);

  Color get _mutedColor =>
      widget.darkMode ? Colors.white70 : Colors.black54;

  @override
  void initState() {
    super.initState();
    _configureTts();
    _getCurrentLocation();
  }

  Future<void> _configureTts() async {
    await _tts.setLanguage('ar');
    await _tts.setSpeechRate(0.48);
    await _tts.setVolume(1.0);
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
      _statusMessage = 'جارٍ تحديد موقعك...';
    });

    try {
      final serviceEnabled =
          await Geolocator.isLocationServiceEnabled();

      if (!serviceEnabled) {
        setState(() {
          _statusMessage = 'فعّل خدمة الموقع GPS من إعدادات الهاتف';
          _loadingLocation = false;
        });
        return;
      }

      LocationPermission permission =
          await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied) {
        setState(() {
          _statusMessage = 'تحتاج تسمح للتطبيق باستخدام الموقع';
          _loadingLocation = false;
        });
        return;
      }

      if (permission == LocationPermission.deniedForever) {
        setState(() {
          _statusMessage =
              'إذن الموقع مرفوض نهائياً. فعّله من إعدادات التطبيق';
          _loadingLocation = false;
        });
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 20),
        ),
      );

      if (!mounted) return;

      _currentLocation = LatLng(
        position.latitude,
        position.longitude,
      );
      _heading = position.heading;
      _currentSpeed = position.speed * 3.6;

      _mapController.move(_currentLocation, 16);

      setState(() {
        _loadingLocation = false;
        _statusMessage = 'تم تحديد موقعك بنجاح';
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _loadingLocation = false;
        _statusMessage = 'تعذّر تحديد الموقع. تحقق من GPS والإنترنت';
      });
    }
  }

  Future<void> _startLocationTracking() async {
    final permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      await _getCurrentLocation();
      return;
    }

    await _positionSubscription?.cancel();

    const settings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 3,
    );

    _positionSubscription =
        Geolocator.getPositionStream(
      locationSettings: settings,
    ).listen((position) {
      if (!mounted) return;

      _currentLocation = LatLng(
        position.latitude,
        position.longitude,
      );

      _heading = position.heading;
      _currentSpeed = position.speed * 3.6;

      if (_navigating) {
        _mapController.move(_currentLocation, 17);
        _updateRouteProgress();
      }

      setState(() {});
    }, onError: (error) {
      if (mounted) {
        setState(() {
          _statusMessage = 'مشكلة بتحديث الموقع GPS';
        });
      }
    });
  }

  Future<void> _searchPlaces(String query) async {
    if (query.trim().isEmpty) return;

    FocusScope.of(context).unfocus();

    setState(() {
      _searching = true;
      _searchResults = [];
      _statusMessage = 'جارٍ البحث عن الأماكن...';
    });

    try {
      final uri = Uri.https(
        'nominatim.openstreetmap.org',
        '/search',
        {
          'q': '$query, Iraq',
          'format': 'jsonv2',
          'limit': '8',
          'countrycodes': 'iq',
          'accept-language': 'ar',
          'addressdetails': '1',
        },
      );

      final response = await http.get(
        uri,
        headers: {
          'User-Agent': 'DaleelIraq/1.0',
          'Accept-Language': 'ar',
        },
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        throw Exception('Search failed');
      }

      final data = jsonDecode(response.body) as List;

      if (!mounted) return;

      setState(() {
        _searchResults = data;
        _searching = false;
        _statusMessage = data.isEmpty
            ? 'ما لكينا نتائج. جرّب اسم مكان آخر'
            : 'اختار المكان اللي تريده';
      });

      if (data.isEmpty) {
        _showMessage('ما لكينا نتائج لهذا البحث');
      } else {
        _showSearchResults();
      }
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _searching = false;
        _statusMessage = 'تعذّر البحث. تحقق من الإنترنت وحاول مرة ثانية';
      });

      _showMessage('فشل البحث. حاول بعد قليل');
    }
  }

  void _showSearchResults() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return Container(
          height: MediaQuery.of(context).size.height * 0.62,
          decoration: BoxDecoration(
            color: _panelColor,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(28),
            ),
          ),
          child: Column(
            children: [
              const SizedBox(height: 12),
              Container(
                width: 42,
                height: 5,
                decoration: BoxDecoration(
                  color: _mutedColor.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(18),
                child: Row(
                  children: [
                    Icon(Icons.location_searching, color: _green),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'نتائج البحث',
                        style: TextStyle(
                          color: _textColor,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.separated(
                  itemCount: _searchResults.length,
                  separatorBuilder: (_, __) => Divider(
                    height: 1,
                    color: _mutedColor.withValues(alpha: 0.15),
                  ),
                  itemBuilder: (context, index) {
                    final item = _searchResults[index];

                    final name = (item['name'] ??
                            item['display_name'] ??
                            'مكان بدون اسم')
                        .toString();

                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor:
                            _green.withValues(alpha: 0.13),
                        child: Icon(
                          Icons.place,
                          color: _green,
                        ),
                      ),
                      title: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _textColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: Text(
                        (item['display_name'] ?? '').toString(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: _mutedColor),
                      ),
                      onTap: () {
                        final lat =
                            double.tryParse(item['lat'].toString());
                        final lon =
                            double.tryParse(item['lon'].toString());

                        if (lat == null || lon == null) return;

                        final point = LatLng(lat, lon);

                        _destination = point;
                        _destinationName = name;
                        _routePoints = [];

                        _mapController.move(point, 15);

                        Navigator.pop(sheetContext);

                        setState(() {
                          _statusMessage = 'تم اختيار: $name';
                          _showSearch = false;
                        });

                        _showMessage('تم اختيار $name');
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

  Future<void> _buildRoute() async {
    if (_destination == null) {
      _showMessage('ابحث عن المكان اللي تريد تروح له أولاً');
      return;
    }

    setState(() {
      _statusMessage = 'جارٍ حساب الطريق...';
    });

    try {
      final start = _currentLocation;
      final end = _destination!;

      final uri = Uri.parse(
        'https://router.project-osrm.org/route/v1/driving/'
        '${start.longitude},${start.latitude};'
        '${end.longitude},${end.latitude}'
        '?overview=full&geometries=geojson&steps=true',
      );

      final response = await http.get(uri).timeout(
            const Duration(seconds: 20),
          );

      if (response.statusCode != 200) {
        throw Exception('Route request failed');
      }

      final data = jsonDecode(response.body);
      final routes = data['routes'] as List?;

      if (routes == null || routes.isEmpty) {
        throw Exception('No route found');
      }

      final route = routes.first;
      final coordinates =
          route['geometry']['coordinates'] as List;

      final points = coordinates.map<LatLng>((coordinate) {
        return LatLng(
          (coordinate[1] as num).toDouble(),
          (coordinate[0] as num).toDouble(),
        );
      }).toList();

      if (!mounted) return;

      setState(() {
        _routePoints = points;
        _remainingKm =
            (route['distance'] as num).toDouble() / 1000;
        _remainingMinutes =
            (route['duration'] as num).toDouble() / 60;
        _statusMessage = 'تم حساب الطريق بنجاح';
      });

      if (points.isNotEmpty) {
        final bounds = LatLngBounds.fromPoints(points);
        _mapController.fitCamera(
          CameraFit.bounds(
            bounds: bounds,
            padding: const EdgeInsets.fromLTRB(45, 150, 45, 240),
          ),
        );
      }

      _showMessage('تم حساب الطريق بنجاح');
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _statusMessage = 'تعذّر حساب الطريق. حاول مرة ثانية';
      });

      _showMessage('تعذّر حساب الطريق. تحقق من الإنترنت');
    }
  }

  Future<void> _startNavigation() async {
    if (_destination == null) {
      _showMessage('حدد وجهتك من البحث أولاً');
      return;
    }

    if (_routePoints.isEmpty) {
      await _buildRoute();
      if (_routePoints.isEmpty) return;
    }

    setState(() {
      _navigating = true;
      _statusMessage = 'بدأت الملاحة إلى $_destinationName';
    });

    await _startLocationTracking();
    await _tts.speak('بدأت الملاحة. انتبه للطريق');
  }

  Future<void> _stopNavigation() async {
    await _positionSubscription?.cancel();
    _positionSubscription = null;
    await _tts.stop();

    if (!mounted) return;

    setState(() {
      _navigating = false;
      _statusMessage = 'تم إيقاف الملاحة';
    });
  }

  void _updateRouteProgress() {
    if (_routePoints.isEmpty || _destination == null) return;

    final distance = const Distance();

    double nearestDistance = double.infinity;
    int nearestIndex = 0;

    for (int i = 0; i < _routePoints.length; i++) {
      final d = distance.as(
        LengthUnit.Meter,
        _currentLocation,
        _routePoints[i],
      );

      if (d < nearestDistance) {
        nearestDistance = d;
        nearestIndex = i;
      }
    }

    double remainingMeters = 0;

    for (int i = nearestIndex; i < _routePoints.length - 1; i++) {
      remainingMeters += distance.as(
        LengthUnit.Meter,
        _routePoints[i],
        _routePoints[i + 1],
      );
    }

    _remainingKm = remainingMeters / 1000;

    final speedMetersPerSecond = _currentSpeed / 3.6;

    if (speedMetersPerSecond > 1) {
      _remainingMinutes =
          remainingMeters / speedMetersPerSecond / 60;
    }

    if (remainingMeters < 35 && mounted) {
      _stopNavigation();
      _tts.speak('وصلت إلى وجهتك');
      setState(() {
        _statusMessage = 'وصلت إلى وجهتك';
      });
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          backgroundColor: _green,
          duration: const Duration(seconds: 2),
        ),
      );
  }

  Widget _roundButton({
    required IconData icon,
    required VoidCallback onTap,
    String? tooltip,
    Color? color,
  }) {
    return Material(
      color: _panelColor,
      elevation: 5,
      shadowColor: Colors.black.withValues(alpha: 0.15),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Tooltip(
            message: tooltip ?? '',
            child: Icon(
              icon,
              color: color ?? _textColor,
              size: 23,
            ),
          ),
        ),
      ),
    );
  }

  Widget _searchBar() {
    return Container(
      decoration: BoxDecoration(
        color: _panelColor,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 18,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 15),
            child: Icon(Icons.search, color: _green, size: 27),
          ),
          Expanded(
            child: TextField(
              controller: _searchController,
              style: TextStyle(
                color: _textColor,
                fontSize: 15,
              ),
              textInputAction: TextInputAction.search,
              onSubmitted: _searchPlaces,
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: 'وين تريد تروح؟',
                hintStyle: TextStyle(color: _mutedColor),
              ),
            ),
          ),
          if (_searching)
            Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: _green,
                ),
              ),
            )
          else
            IconButton(
              tooltip: 'ابحث',
              onPressed: () =>
                  _searchPlaces(_searchController.text),
              icon: Icon(Icons.arrow_forward, color: _green),
            ),
        ],
      ),
    );
  }

  Widget _topPanel() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  width: 47,
                  height: 47,
                  decoration: BoxDecoration(
                    color: _green,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: _green.withValues(alpha: 0.3),
                        blurRadius: 12,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.navigation_rounded,
                    color: Colors.white,
                    size: 28,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'دليل العراق',
                        style: TextStyle(
                          color: _textColor,
                          fontWeight: FontWeight.w900,
                          fontSize: 20,
                        ),
                      ),
                      Text(
                        'طريقك أسهل',
                        style: TextStyle(
                          color: _mutedColor,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                _roundButton(
                  icon: widget.darkMode
                      ? Icons.light_mode_rounded
                      : Icons.dark_mode_rounded,
                  tooltip: widget.darkMode
                      ? 'الوضع النهاري'
                      : 'الوضع الليلي',
                  onTap: widget.onThemeChanged,
                  color: _green,
                ),
              ],
            ),
            const SizedBox(height: 13),
            _searchBar(),
          ],
        ),
      ),
    );
  }

  Widget _vehicleMarker() {
    return Transform.rotate(
      angle: _heading * math.pi / 180,
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: _green,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: [
            BoxShadow(
              color: _green.withValues(alpha: 0.4),
              blurRadius: 15,
              spreadRadius: 2,
            ),
          ],
        ),
        child: const Icon(
          Icons.navigation_rounded,
          color: Colors.white,
          size: 26,
        ),
      ),
    );
  }

  Widget _bottomPanel() {
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: _panelColor,
          borderRadius: BorderRadius.circular(26),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 25,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: _green.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(15),
                  ),
                  child: Icon(
                    _navigating
                        ? Icons.navigation_rounded
                        : Icons.explore_rounded,
                    color: _green,
                    size: 25,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _navigating
                            ? 'الملاحة شغّالة'
                            : _destinationName.isNotEmpty
                                ? _destinationName
                                : 'جاهز لرحلتك؟',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _textColor,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _statusMessage,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _mutedColor,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                if (_loadingLocation)
                  SizedBox(
                    width: 23,
                    height: 23,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: _green,
                    ),
                  )
                else
                  Icon(
                    Icons.circle,
                    color: _green,
                    size: 11,
                  ),
              ],
            ),
            if (_navigating || _routePoints.isNotEmpty) ...[
              const SizedBox(height: 17),
              Divider(
                color: _mutedColor.withValues(alpha: 0.2),
                height: 1,
              ),
              const SizedBox(height: 15),
              Row(
                children: [
                  Expanded(
                    child: _stat(
                      Icons.route_rounded,
                      '${_remainingKm.toStringAsFixed(1)} كم',
                      'المسافة',
                    ),
                  ),
                  Expanded(
                    child: _stat(
                      Icons.schedule_rounded,
                      '${_remainingMinutes.round()} دقيقة',
                      'الوقت التقريبي',
                    ),
                  ),
                  Expanded(
                    child: _stat(
                      Icons.speed_rounded,
                      '${_currentSpeed.round()}',
                      'كم/ساعة',
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _navigating
                        ? _stopNavigation
                        : _startNavigation,
                    icon: Icon(
                      _navigating
                          ? Icons.stop_circle_outlined
                          : Icons.navigation_rounded,
                    ),
                    label: Text(
                      _navigating ? 'إيقاف الملاحة' : 'ابدأ الملاحة',
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor:
                          _navigating ? Colors.redAccent : _green,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(0, 52),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(17),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                _roundButton(
                  icon: Icons.alt_route_rounded,
                  tooltip: 'احسب الطريق',
                  color: _green,
                  onTap: _buildRoute,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(IconData icon, String value, String label) {
    return Column(
      children: [
        Icon(icon, color: _green, size: 22),
        const SizedBox(height: 6),
        Text(
          value,
          style: TextStyle(
            color: _textColor,
            fontSize: 15,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: _mutedColor,
            fontSize: 11,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final tileUrl = widget.darkMode
        ? 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png'
        : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

    return Scaffold(
      backgroundColor: widget.darkMode
          ? const Color(0xFF111820)
          : const Color(0xFFF3F6F5),
      body: Stack(
        children: [
          Positioned.fill(
            child: FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: _currentLocation,
                initialZoom: 13,
                minZoom: 4,
                maxZoom: 19,
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.all,
                ),
              ),
              children: [
                TileLayer(
                  urlTemplate: tileUrl,
                  userAgentPackageName: 'com.daleeliraq.app',
                  maxNativeZoom: 19,
                ),
                if (_routePoints.isNotEmpty)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: _routePoints,
                        strokeWidth: 10,
                        color: _green.withValues(alpha: 0.22),
                      ),
                      Polyline(
                        points: _routePoints,
                        strokeWidth: 5,
                        color: const Color(0xFF1787FF),
                      ),
                    ],
                  ),
                MarkerLayer(
                  markers: [
                    Marker(
                      point: _currentLocation,
                      width: 58,
                      height: 58,
                      child: _vehicleMarker(),
                    ),
                    if (_destination != null)
                      Marker(
                        point: _destination!,
                        width: 48,
                        height: 48,
                        child: const Icon(
                          Icons.location_on_rounded,
                          color: Colors.redAccent,
                          size: 43,
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

          // شريط البحث والهوية
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _topPanel(),
          ),

          // أزرار التحكم بالخريطة
          Positioned(
            left: 14,
            bottom: 245,
            child: Column(
              children: [
                _roundButton(
                  icon: Icons.my_location_rounded,
                  tooltip: 'موقعي الحالي',
                  color: _green,
                  onTap: _getCurrentLocation,
                ),
                const SizedBox(height: 12),
                _roundButton(
                  icon: Icons.add_rounded,
                  tooltip: 'تكبير الخريطة',
                  onTap: () {
                    final camera = _mapController.camera;
                    _mapController.move(
                      camera.center,
                      (camera.zoom + 1).clamp(4, 19).toDouble(),
                    );
                  },
                ),
                const SizedBox(height: 12),
                _roundButton(
                  icon: Icons.remove_rounded,
                  tooltip: 'تصغير الخريطة',
                  onTap: () {
                    final camera = _mapController.camera;
                    _mapController.move(
                      camera.center,
                      (camera.zoom - 1).clamp(4, 19).toDouble(),
                    );
                  },
                ),
              ],
            ),
          ),

          // لوحة الملاحة السفلية
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: _bottomPanel(),
          ),
        ],
      ),
    );
  }
}
