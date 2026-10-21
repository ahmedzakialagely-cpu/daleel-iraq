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
  WidgetsFlutterBinding.ensureInitialized();
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
      title: 'دليل العراق',
      theme: ThemeData(
        useMaterial3: true,
        brightness: brightness,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1688FF),
          brightness: brightness,
        ),
        scaffoldBackgroundColor:
            darkMode ? const Color(0xFF101820) : const Color(0xFFF4F6F8),
      ),
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: NavigationScreen(
          darkMode: darkMode,
          onThemeChanged: () => setState(() => darkMode = !darkMode),
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

  LatLng _currentLocation = const LatLng(33.3152, 44.3661);
  LatLng? _destination;
  List<LatLng> _routePoints = [];
  List<dynamic> _searchResults = [];
  StreamSubscription<Position>? _positionSubscription;

  bool _loadingLocation = false;
  bool _searching = false;
  bool _navigating = false;
  bool _followingLocation = true;
  bool _satelliteMode = false;
  bool _isRerouting = false;

  double _heading = 0;
  double _speedKmh = 0;
  double _remainingKm = 0;
  double _remainingMinutes = 0;

  String _statusMessage = 'أهلاً بك في دليل العراق';
  String _destinationName = '';

  static const Color _blue = Color(0xFF1688FF);
  Color get _panelColor =>
      widget.darkMode ? const Color(0xFF202833) : Colors.white;
  Color get _textColor =>
      widget.darkMode ? Colors.white : const Color(0xFF202124);
  Color get _mutedColor =>
      widget.darkMode ? const Color(0xFFB6C0CB) : const Color(0xFF697078);

  // Street map: OpenStreetMap. Satellite imagery: Esri World Imagery.
  // Check each provider's current terms and attribution before production use.
  String get _tileUrl => _satelliteMode
      ? 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}'
      : widget.darkMode
          ? 'https://basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png'
          : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

  @override
  void initState() {
    super.initState();
    _configureVoice();
    _getCurrentLocation();
  }

  Future<void> _configureVoice() async {
    try {
      await _tts.setLanguage('ar');
      await _tts.setSpeechRate(0.45);
      await _tts.setVolume(1);
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
      _statusMessage = 'جارٍ تحديد موقعك...';
    });
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _setLocationError('فعّل خدمة الموقع GPS من إعدادات الهاتف');
        return;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        _setLocationError('اسمح للتطبيق باستخدام موقعك');
        return;
      }
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 20),
        ),
      );
      if (!mounted) return;
      _currentLocation = LatLng(p.latitude, p.longitude);
      if (p.heading >= 0) _heading = p.heading;
      _speedKmh = math.max(0.0, p.speed * 3.6);
      _mapController.move(_currentLocation, 16);
      setState(() {
        _loadingLocation = false;
        _statusMessage = 'تم تحديد موقعك';
      });
    } catch (_) {
      _setLocationError('تعذّر تحديد الموقع. تحقق من GPS وصلاحية الموقع');
    }
  }

  void _setLocationError(String message) {
    if (!mounted) return;
    setState(() {
      _loadingLocation = false;
      _statusMessage = message;
    });
  }

  Future<bool> _ensureLocationPermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      _showMessage('فعّل GPS أولاً');
      return false;
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      _showMessage('اسمح للتطبيق باستخدام الموقع من إعدادات الهاتف');
      return false;
    }
    return true;
  }

  Future<void> _startTracking() async {
    if (!await _ensureLocationPermission()) return;
    await _positionSubscription?.cancel();
    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 3,
      ),
    ).listen((p) {
      if (!mounted) return;
      _currentLocation = LatLng(p.latitude, p.longitude);
      if (p.heading >= 0 && p.speed > 0.8) _heading = p.heading;
      _speedKmh = math.max(0.0, p.speed * 3.6);
      if (_followingLocation) {
        _mapController.move(
          _currentLocation,
          _navigating ? 17 : _mapController.camera.zoom,
        );
      }
      if (_navigating) _updateProgressAndReroute();
      if (mounted) setState(() {});
    }, onError: (_) {
      if (mounted) setState(() => _statusMessage = 'تعذّر تحديث GPS');
    });
  }

  void _updateProgressAndReroute() {
    if (_routePoints.length < 2 || _destination == null || _isRerouting) return;
    var nearestIndex = 0;
    var nearestDistance = double.infinity;
    for (var i = 0; i < _routePoints.length; i++) {
      final d = _distance.as(LengthUnit.Meter, _currentLocation, _routePoints[i]);
      if (d < nearestDistance) {
        nearestDistance = d;
        nearestIndex = i;
      }
    }
    // OSRM routes may not contain a point exactly under the GPS dot.
    if (nearestDistance > 80) {
      _triggerAutoReroute();
      return;
    }
    var remainingMeters = 0.0;
    for (var i = nearestIndex; i < _routePoints.length - 1; i++) {
      remainingMeters += _distance.as(
        LengthUnit.Meter,
        _routePoints[i],
        _routePoints[i + 1],
      );
    }
    _remainingKm = remainingMeters / 1000;
    if (_speedKmh > 1) {
      _remainingMinutes = remainingMeters / (_speedKmh / 3.6) / 60;
    }
    if (remainingMeters < 35 && _navigating) {
      _stopNavigation();
      _tts.speak('وصلت إلى وجهتك');
    }
  }

  Future<void> _triggerAutoReroute() async {
    _isRerouting = true;
    if (mounted) setState(() => _statusMessage = 'جارٍ إعادة حساب المسار...');
    try {
      await _tts.speak('جارٍ إعادة حساب المسار');
      await _calculateRoute(showMessage: false);
    } finally {
      _isRerouting = false;
    }
  }

  Future<void> _searchPlaces(String query) async {
    if (query.trim().isEmpty) {
      _showMessage('اكتب اسم المكان الذي تريد البحث عنه');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = true;
      _statusMessage = 'جارٍ البحث عن الأماكن...';
    });
    try {
      final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
        'q': '$query, Iraq',
        'format': 'jsonv2',
        'limit': '8',
        'countrycodes': 'iq',
        'accept-language': 'ar',
        'addressdetails': '1',
      });
      final response = await http.get(uri, headers: {
        'User-Agent': 'DaleelIraqApp/1.0 (Iraq navigation app)',
        'Accept-Language': 'ar',
      }).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) throw Exception('Search failed');
      final results = jsonDecode(response.body) as List;
      if (!mounted) return;
      setState(() {
        _searchResults = results;
        _searching = false;
        _statusMessage = results.isEmpty ? 'لم نجد نتائج' : 'اختر المكان المطلوب';
      });
      if (results.isEmpty) {
        _showMessage('لم نجد نتائج. جرّب اسماً آخر');
      } else {
        _showSearchResults();
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _statusMessage = 'تعذّر البحث. تحقق من الإنترنت';
      });
      _showMessage('فشل البحث. حاول بعد قليل');
    }
  }

  void _showSearchResults() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Container(
        height: MediaQuery.of(context).size.height * 0.65,
        decoration: BoxDecoration(
          color: _panelColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
        ),
        child: Column(children: [
          const SizedBox(height: 12),
          Container(
            width: 42, height: 5,
            decoration: BoxDecoration(color: _mutedColor.withValues(alpha: .4),
              borderRadius: BorderRadius.circular(8)),
          ),
          Padding(
            padding: const EdgeInsets.all(18),
            child: Row(children: [
              const Icon(Icons.search, color: _blue),
              const SizedBox(width: 10),
              Text('نتائج البحث', style: TextStyle(
                color: _textColor, fontSize: 20, fontWeight: FontWeight.bold)),
            ]),
          ),
          Expanded(
            child: ListView.separated(
              itemCount: _searchResults.length,
              separatorBuilder: (_, __) => Divider(
                height: 1, color: _mutedColor.withValues(alpha: .15)),
              itemBuilder: (context, index) {
                final item = _searchResults[index];
                final name = (item['name'] ?? item['display_name'] ?? 'مكان').toString();
                return ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Color(0x221688FF),
                    child: Icon(Icons.place, color: _blue)),
                  title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: _textColor, fontWeight: FontWeight.bold)),
                  subtitle: Text((item['display_name'] ?? '').toString(),
                    maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: _mutedColor)),
                  onTap: () {
                    final lat = double.tryParse(item['lat'].toString());
                    final lon = double.tryParse(item['lon'].toString());
                    if (lat == null || lon == null) return;
                    _destination = LatLng(lat, lon);
                    _destinationName = name;
                    _routePoints = [];
                    _mapController.move(_destination!, 15);
                    Navigator.pop(sheetContext);
                    setState(() => _statusMessage = 'تم اختيار: $_destinationName');
                    _showMessage('تم اختيار $_destinationName');
                  },
                );
              },
            ),
          ),
        ]),
      ),
    );
  }

  Future<void> _calculateRoute({bool showMessage = true}) async {
    if (_destination == null) {
      if (showMessage) _showMessage('ابحث عن وجهتك أولاً');
      return;
    }
    setState(() => _statusMessage = 'جارٍ حساب المسار...');
    try {
      final start = _currentLocation;
      final end = _destination!;
      final uri = Uri.parse(
        'https://router.project-osrm.org/route/v1/driving/'
        '${start.longitude},${start.latitude};${end.longitude},${end.latitude}'
        '?overview=full&geometries=geojson&steps=true',
      );
      final response = await http.get(uri, headers: {
        'User-Agent': 'DaleelIraqApp/1.0'
      }).timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) throw Exception('Route failed');
      final data = jsonDecode(response.body);
      final routes = data['routes'] as List?;
      if (routes == null || routes.isEmpty) throw Exception('No route');
      final route = routes.first;
      final coordinates = route['geometry']['coordinates'] as List;
      final points = coordinates.map<LatLng>((p) => LatLng(
        (p[1] as num).toDouble(), (p[0] as num).toDouble())).toList();
      if (!mounted) return;
      setState(() {
        _routePoints = points;
        _remainingKm = (route['distance'] as num).toDouble() / 1000;
        _remainingMinutes = (route['duration'] as num).toDouble() / 60;
        _statusMessage = 'تم حساب المسار';
      });
      if (points.isNotEmpty) {
        _mapController.fitCamera(CameraFit.bounds(
          bounds: LatLngBounds.fromPoints(points),
          padding: const EdgeInsets.fromLTRB(40, 150, 40, 240),
        ));
      }
      if (showMessage) _showMessage('تم حساب المسار بنجاح');
    } catch (_) {
      if (!mounted) return;
      setState(() => _statusMessage = 'تعذّر حساب الطريق');
      if (showMessage) _showMessage('تعذّر حساب الطريق. تحقق من الإنترنت');
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
      _statusMessage = 'الملاحة إلى $_destinationName';
    });
    await _startTracking();
    await _tts.speak('بدأت الملاحة. انتبه للطريق');
  }

  Future<void> _stopNavigation() async {
    await _positionSubscription?.cancel();
    _positionSubscription = null;
    await _tts.stop();
    if (!mounted) return;
    setState(() {
      _navigating = false;
      _followingLocation = false;
      _statusMessage = 'تم إيقاف الملاحة';
    });
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message, style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: _blue,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ));
  }

  Widget _roundButton({
    required IconData icon,
    required VoidCallback onTap,
    String? tooltip,
    Color? iconColor,
  }) {
    return Material(
      color: _panelColor,
      elevation: 5,
      shadowColor: Colors.black.withValues(alpha: .18),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 48, height: 48,
          child: Tooltip(message: tooltip ?? '', child: Icon(
            icon, color: iconColor ?? _textColor, size: 23)),
        ),
      ),
    );
  }

  Widget _searchBar() {
    return Container(
      height: 56,
      decoration: BoxDecoration(
        color: _panelColor,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [BoxShadow(
          color: Colors.black.withValues(alpha: .16),
          blurRadius: 18, offset: const Offset(0, 5))],
      ),
      child: Row(children: [
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 14),
          child: Icon(Icons.search_rounded, color: _blue, size: 27)),
        Expanded(child: TextField(
          controller: _searchController,
          textInputAction: TextInputAction.search,
          onSubmitted: _searchPlaces,
          style: TextStyle(color: _textColor),
          decoration: InputDecoration(
            hintText: 'ابحث عن مكان في العراق...',
            hintStyle: TextStyle(color: _mutedColor, fontSize: 14),
            border: InputBorder.none,
          ),
        )),
        if (_searching)
          const Padding(
            padding: EdgeInsets.all(14),
            child: SizedBox(width: 20, height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: _blue)))
        else
          IconButton(
            onPressed: () => _searchPlaces(_searchController.text),
            icon: const Icon(Icons.arrow_forward_rounded, color: _blue)),
      ]),
    );
  }

  Widget _topPanel() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Container(
              width: 46, height: 46,
              decoration: BoxDecoration(
                color: _blue, borderRadius: BorderRadius.circular(15)),
              child: const Icon(Icons.navigation_rounded,
                color: Colors.white, size: 28)),
            const SizedBox(width: 11),
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('دليل العراق', style: TextStyle(
                  color: _textColor, fontSize: 20, fontWeight: FontWeight.w900)),
                Text('طريقك أسهل', style: TextStyle(color: _mutedColor, fontSize: 12)),
              ],
            )),
            _roundButton(
              icon: widget.darkMode ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
              tooltip: widget.darkMode ? 'الوضع النهاري' : 'الوضع الليلي',
              iconColor: _blue, onTap: widget.onThemeChanged),
          ]),
          const SizedBox(height: 12),
          _searchBar(),
        ]),
      ),
    );
  }

  Widget _vehicleMarker() {
    return Transform.rotate(
      angle: _heading * math.pi / 180,
      child: Container(
        width: 46, height: 46,
        decoration: BoxDecoration(
          color: _blue, shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: [BoxShadow(
            color: _blue.withValues(alpha: .35), blurRadius: 14, spreadRadius: 2)],
        ),
        child: const Icon(Icons.navigation_rounded, color: Colors.white, size: 26),
      ),
    );
  }

  Widget _stat(IconData icon, String value, String label) {
    return Column(children: [
      Icon(icon, color: _blue, size: 23),
      const SizedBox(height: 6),
      Text(value, style: TextStyle(
        color: _textColor, fontSize: 15, fontWeight: FontWeight.bold)),
      const SizedBox(height: 3),
      Text(label, style: TextStyle(color: _mutedColor, fontSize: 11)),
    ]);
  }

  Widget _bottomPanel() {
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: _panelColor,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [BoxShadow(
            color: Colors.black.withValues(alpha: .20),
            blurRadius: 24, offset: const Offset(0, 5))],
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                color: _blue.withValues(alpha: .12),
                borderRadius: BorderRadius.circular(14)),
              child: Icon(_navigating ? Icons.navigation_rounded : Icons.place_rounded,
                color: _blue, size: 25)),
            const SizedBox(width: 11),
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _navigating ? 'الملاحة نشطة' :
                    (_destinationName.isNotEmpty ? _destinationName : 'وين وجهتك اليوم؟'),
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: _textColor,
                    fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 4),
                Text(_statusMessage, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: _mutedColor, fontSize: 12)),
              ],
            )),
            if (_loadingLocation)
              const SizedBox(width: 20, height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: _blue))
            else
              const Icon(Icons.circle, color: Colors.green, size: 10),
          ]),
          if (_routePoints.isNotEmpty || _navigating) ...[
            const SizedBox(height: 14),
            Divider(height: 1, color: _mutedColor.withValues(alpha: .2)),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(child: _stat(Icons.route_rounded,
                '${_remainingKm.toStringAsFixed(1)} كم', 'المسافة')),
              Expanded(child: _stat(Icons.schedule_rounded,
                '${_remainingMinutes.round()} د', 'الوقت التقريبي')),
              Expanded(child: _stat(Icons.speed_rounded,
                '${_speedKmh.round()} كم/س', 'السرعة')),
            ]),
          ],
          const SizedBox(height: 14),
          Row(children: [
            Expanded(child: ElevatedButton.icon(
              onPressed: _navigating ? _stopNavigation : _startNavigation,
              icon: Icon(_navigating ? Icons.stop_circle_outlined : Icons.navigation_rounded),
              label: Text(_navigating ? 'إيقاف الملاحة' : 'ابدأ الملاحة',
                style: const TextStyle(fontWeight: FontWeight.bold)),
              style: ElevatedButton.styleFrom(
                backgroundColor: _blue, foregroundColor: Colors.white,
                minimumSize: const Size(0, 51),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
              ),
            )),
            const SizedBox(width: 9),
            _roundButton(icon: Icons.alt_route_rounded, tooltip: 'احسب الطريق',
              iconColor: _blue, onTap: _calculateRoute),
          ]),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(children: [
        Positioned.fill(
          child: FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _currentLocation,
              initialZoom: 13,
              minZoom: 4,
              maxZoom: 19,
              interactionOptions: const InteractionOptions(flags: InteractiveFlag.all),
              onPositionChanged: (camera, hasGesture) {
                if (hasGesture && !_navigating) _followingLocation = false;
              },
            ),
            children: [
              TileLayer(
                key: ValueKey('${_satelliteMode}_${widget.darkMode}'),
                urlTemplate: _tileUrl,
                userAgentPackageName: 'com.daleeliraq.app',
                maxNativeZoom: 19,
              ),
              if (_routePoints.isNotEmpty)
                PolylineLayer(polylines: [
                  Polyline(points: _routePoints, strokeWidth: 10,
                    color: Colors.white.withValues(alpha: .8)),
                  Polyline(points: _routePoints, strokeWidth: 6, color: _blue),
                ]),
              MarkerLayer(markers: [
                Marker(point: _currentLocation, width: 54, height: 54,
                  child: _vehicleMarker()),
                if (_destination != null)
                  Marker(point: _destination!, width: 44, height: 44,
                    child: const Icon(Icons.location_on_rounded,
                      color: Colors.red, size: 42)),
              ]),
              const RichAttributionWidget(attributions: [
                TextSourceAttribution('© OpenStreetMap contributors'),
                TextSourceAttribution('Imagery © Esri (satellite layer)'),
              ]),
            ],
          ),
        ),
        Positioned(top: 0, left: 0, right: 0, child: _topPanel()),
        Positioned(
          left: 14, bottom: 245,
          child: Column(children: [
            _roundButton(
              icon: _satelliteMode ? Icons.map_rounded : Icons.satellite_alt_rounded,
              tooltip: _satelliteMode ? 'خريطة الشوارع' : 'صور الأقمار الصناعية',
              iconColor: _blue,
              onTap: () => setState(() => _satelliteMode = !_satelliteMode),
            ),
            const SizedBox(height: 11),
            _roundButton(
              icon: Icons.my_location_rounded, tooltip: 'موقعي', iconColor: _blue,
              onTap: () async {
                _followingLocation = true;
                await _getCurrentLocation();
                if (mounted) _mapController.move(_currentLocation, _navigating ? 17 : 16);
              }),
            const SizedBox(height: 11),
            _roundButton(icon: Icons.add_rounded, tooltip: 'تكبير', onTap: () {
              final c = _mapController.camera;
              _mapController.move(c.center, (c.zoom + 1).clamp(4, 19).toDouble());
            }),
            const SizedBox(height: 11),
            _roundButton(icon: Icons.remove_rounded, tooltip: 'تصغير', onTap: () {
              final c = _mapController.camera;
              _mapController.move(c.center, (c.zoom - 1).clamp(4, 19).toDouble());
            }),
          ]),
        ),
        Positioned(bottom: 0, left: 0, right: 0, child: _bottomPanel()),
      ]),
    );
  }
}
