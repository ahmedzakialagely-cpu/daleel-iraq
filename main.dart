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

/// نموذج التقرير الخاص بالسائقين (Waze-style Report)
class DriverReport {
  final String id;
  final String type; // ازدحام، سيطرة، حادث، شارع مغلق، حفرة
  final LatLng location;
  final String description;
  final DateTime timestamp;

  DriverReport({
    required this.id,
    required this.type,
    required this.location,
    required this.description,
    required this.timestamp,
  });
}

class DaleelIraqApp extends StatefulWidget {
  const DaleelIraqApp({super.key});

  @override
  State<DaleelIraqApp> createState() => _DaleelIraqAppState();
}

class _DaleelIraqAppState extends State<DaleelIraqApp> {
  bool darkMode = true;

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
          seedColor: const Color(0xFF22D39A),
          brightness: brightness,
        ),
        scaffoldBackgroundColor:
            darkMode ? const Color(0xFF101820) : const Color(0xFFF1F4F5),
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
  final List<DriverReport> _activeReports = [];

  StreamSubscription<Position>? _positionSubscription;

  bool _loadingLocation = false;
  bool _searching = false;
  bool _navigating = false;
  bool _followingLocation = true;
  bool _isRerouting = false;

  double _heading = 0;
  double _speedKmh = 0;
  double _remainingKm = 0;
  double _remainingMinutes = 0;
  final double _speedLimit = 100; // حد السرعة الافتراضي

  String _statusMessage = 'أهلاً بك في دليل العراق';
  String _destinationName = '';

  Color get _green => const Color(0xFF22D39A);

  Color get _panelColor =>
      widget.darkMode ? const Color(0xFF202B35) : Colors.white;

  Color get _textColor =>
      widget.darkMode ? Colors.white : const Color(0xFF17212B);

  Color get _mutedColor =>
      widget.darkMode ? const Color(0xFFB5C0CB) : Colors.black54;

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
      _statusMessage = 'جارٍ تحديد موقعك...';
    });

    try {
      final enabled = await Geolocator.isLocationServiceEnabled();

      if (!enabled) {
        _setLocationError('فعّل GPS من إعدادات الهاتف');
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        _setLocationError('اسمح للتطبيق باستخدام موقعك');
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

      if (position.heading >= 0) {
        _heading = position.heading;
      }

      _speedKmh = math.max(0, position.speed * 3.6);
      _mapController.move(_currentLocation, 16);

      setState(() {
        _loadingLocation = false;
        _statusMessage = 'تم تحديد موقعك بنجاح';
      });
    } catch (_) {
      _setLocationError('تعذّر تحديد الموقع. تحقق من GPS والإنترنت');
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
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();

    if (!serviceEnabled) {
      _showMessage('فعّل GPS أولاً');
      return;
    }

    var permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      _showMessage('التطبيق يحتاج إذن الموقع');
      return;
    }

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

        double newSpeed = math.max(0, position.speed * 3.6);
        
        // تنبيه تجاوز السرعة (Speed Camera Alert)
        if (newSpeed > _speedLimit && _speedKmh <= _speedLimit) {
          _tts.speak('تنبيه! تجاوزت السرعة المسموحة');
        }
        _speedKmh = newSpeed;

        if (_followingLocation) {
          _mapController.move(
            _currentLocation,
            _navigating ? 17 : _mapController.camera.zoom,
          );
        }

        if (_navigating) {
          _updateProgressAndRerouteIfNeeded();
        }

        if (mounted) setState(() {});
      },
      onError: (_) {
        if (mounted) {
          setState(() => _statusMessage = 'تعذّر تحديث GPS');
        }
      },
    );
  }

  /// إعادة حساب المسار التلقائي في حال الخروج عن الطريق (Off-Route Rerouting)
  void _updateProgressAndRerouteIfNeeded() {
    if (_routePoints.isEmpty || _destination == null || _isRerouting) return;

    int nearestIndex = 0;
    double minDistance = double.infinity;

    for (int i = 0; i < _routePoints.length; i++) {
      final d = _distance.as(
        LengthUnit.Meter,
        _currentLocation,
        _routePoints[i],
      );

      if (d < minDistance) {
        minDistance = d;
        nearestIndex = i;
      }
    }

    // إذا ابتعد السائق عن المسار أكثر من 40 متراً، يُعاد التوجيه تلقائياً
    if (minDistance > 40) {
      _triggerAutoReroute();
      return;
    }

    double remainingMeters = 0;
    for (int i = nearestIndex; i < _routePoints.length - 1; i++) {
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

    if (remainingMeters < 30 && _navigating) {
      _stopNavigation();
      _tts.speak('وصلت إلى وجهتك بنجاح');
    }
  }

  Future<void> _triggerAutoReroute() async {
    _isRerouting = true;
    setState(() => _statusMessage = 'تم الخروج عن المسار، جارٍ إعادة التوجيه...');
    try {
      await _tts.speak('جارٍ إعادة حساب المسار');
      await _calculateRoute(showSnackbar: false);
    } catch (_) {
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
          'User-Agent': 'DaleelIraqApp/1.0',
          'Accept-Language': 'ar',
        },
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        throw Exception('Search failed');
      }

      final results = jsonDecode(response.body) as List;

      if (!mounted) return;

      setState(() {
        _searchResults = results;
        _searching = false;
        _statusMessage = results.isEmpty
            ? 'لم نجد نتائج لهذا البحث'
            : 'اختر المكان المطلوب';
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
        _statusMessage = 'تعذّر البحث. تحقق من الاتصال بالإنترنت';
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
                  color: _mutedColor.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(18),
                child: Row(
                  children: [
                    Icon(Icons.search_rounded, color: _green),
                    const SizedBox(width: 10),
                    Text(
                      'نتائج البحث',
                      style: TextStyle(
                        color: _textColor,
                        fontSize: 20,
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
                    color: _mutedColor.withValues(alpha: 0.15),
                    height: 1,
                  ),
                  itemBuilder: (context, index) {
                    final item = _searchResults[index];
                    final name =
                        (item['name'] ?? item['display_name'] ?? 'مكان')
                            .toString();

                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: _green.withValues(alpha: 0.14),
                        child: Icon(Icons.place, color: _green),
                      ),
                      title: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _textColor,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      subtitle: Text(
                        (item['display_name'] ?? '').toString(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: _mutedColor),
                      ),
                      onTap: () {
                        final lat = double.tryParse(item['lat'].toString());
                        final lon = double.tryParse(item['lon'].toString());

                        if (lat == null || lon == null) return;

                        _destination = LatLng(lat, lon);
                        _destinationName = name;
                        _routePoints = [];

                        _mapController.move(_destination!, 15);
                        Navigator.pop(sheetContext);

                        setState(() {
                          _statusMessage = 'تم اختيار: $_destinationName';
                        });

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

  Future<void> _calculateRoute({bool showSnackbar = true}) async {
    if (_destination == null) {
      if (showSnackbar) _showMessage('ابحث عن وجهتك أولاً');
      return;
    }

    setState(() => _statusMessage = 'جارٍ حساب المسار...');

    try {
      final start = _currentLocation;
      final end = _destination!;

      final uri = Uri.parse(
        'https://router.project-osrm.org/route/v1/driving/'
        '${start.longitude},${start.latitude};'
        '${end.longitude},${end.latitude}'
        '?overview=full&geometries=geojson&steps=true',
      );

      final response = await http.get(
        uri,
        headers: {'User-Agent': 'DaleelIraqApp/1.0'},
      ).timeout(const Duration(seconds: 20));

      if (response.statusCode != 200) {
        throw Exception('Route request failed');
      }

      final data = jsonDecode(response.body);
      final routes = data['routes'] as List?;

      if (routes == null || routes.isEmpty) {
        throw Exception('No route');
      }

      final route = routes.first;
      final coordinates = route['geometry']['coordinates'] as List;

      final points = coordinates.map<LatLng>((point) {
        return LatLng(
          (point[1] as num).toDouble(),
          (point[0] as num).toDouble(),
        );
      }).toList();

      if (!mounted) return;

      setState(() {
        _routePoints = points;
        _remainingKm = (route['distance'] as num).toDouble() / 1000;
        _remainingMinutes = (route['duration'] as num).toDouble() / 60;
        _statusMessage = 'تم حساب المسار بنجاح';
      });

      if (points.isNotEmpty) {
        _mapController.fitCamera(
          CameraFit.bounds(
            bounds: LatLngBounds.fromPoints(points),
            padding: const EdgeInsets.fromLTRB(45, 160, 45, 260),
          ),
        );
      }

      if (showSnackbar) _showMessage('تم حساب المسار بنجاح');
    } catch (_) {
      if (!mounted) return;

      setState(() => _statusMessage = 'تعذّر حساب الطريق');
      if (showSnackbar) _showMessage('تعذّر حساب الطريق. تحقق من الإنترنت');
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
      _statusMessage = 'جاري الملاحة إلى $_destinationName';
    });

    await _startTracking();

    try {
      await _tts.speak('بدأت الملاحة. انتبه للطريق');
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

  /// نافذة إضافة تقرير سائق (Waze Report BottomSheet)
  void _showAddReportModal() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: _panelColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'إبلاغ السائقين (Waze Report)',
                style: TextStyle(
                  color: _textColor,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 15),
              GridView.count(
                shrinkWrap: true,
                crossAxisCount: 3,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                children: [
                  _reportOption(ctx, 'ازدحام مروري', Icons.traffic, Colors.orange),
                  _reportOption(ctx, 'سيطرة', Icons.local_police, Colors.blue),
                  _reportOption(ctx, 'حادث سير', Icons.warning_rounded, Colors.red),
                  _reportOption(ctx, 'شارع مغلق', Icons.block, Colors.purple),
                  _reportOption(ctx, 'حفرة / صيانة', Icons.construction, Colors.amber),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _reportOption(
      BuildContext ctx, String label, IconData icon, Color color) {
    return InkWell(
      onTap: () {
        Navigator.pop(ctx);
        setState(() {
          _activeReports.add(
            DriverReport(
              id: DateTime.now().millisecondsSinceEpoch.toString(),
              type: label,
              location: _currentLocation,
              description: 'بلاغ عن $label بواسطة سائق قريب',
              timestamp: DateTime.now(),
            ),
          );
        });
        _showMessage('تمت إضافة البلاغ: $label');
        _tts.speak('تمت إضافة التنبيه بنجاح');
      },
      child: Container(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color, width: 1.5),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 30),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                color: _textColor,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  IconData _getReportIcon(String type) {
    switch (type) {
      case 'ازدحام مروري':
        return Icons.traffic;
      case 'سيطرة':
        return Icons.local_police;
      case 'حادث سير':
        return Icons.warning_rounded;
      case 'شارع مغلق':
        return Icons.block;
      default:
        return Icons.construction;
    }
  }

  Color _getReportColor(String type) {
    switch (type) {
      case 'ازدحام مروري':
        return Colors.orange;
      case 'سيطرة':
        return Colors.blue;
      case 'حادث سير':
        return Colors.red;
      case 'شارع مغلق':
        return Colors.purple;
      default:
        return Colors.amber;
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            message,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          backgroundColor: _green,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
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
      shadowColor: Colors.black.withValues(alpha: 0.2),
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
              color: iconColor ?? _textColor,
              size: 23,
            ),
          ),
        ),
      ),
    );
  }

  Widget _searchBar() {
    return Container(
      height: 57,
      decoration: BoxDecoration(
        color: _panelColor,
        borderRadius: BorderRadius.circular(19),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 18,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Icon(Icons.search_rounded, color: _green, size: 27),
          ),
          Expanded(
            child: TextField(
              controller: _searchController,
              textInputAction: TextInputAction.search,
              onSubmitted: _searchPlaces,
              style: TextStyle(color: _textColor),
              decoration: InputDecoration(
                hintText: 'وين تريد تروح؟ (مثلاً: بغداد، الكرادة...)',
                hintStyle: TextStyle(color: _mutedColor, fontSize: 14),
                border: InputBorder.none,
              ),
            ),
          ),
          if (_searching)
            Padding(
              padding: const EdgeInsets.all(14),
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
              onPressed: () => _searchPlaces(_searchController.text),
              icon: Icon(Icons.arrow_forward_rounded, color: _green),
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
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: _green,
                    borderRadius: BorderRadius.circular(15),
                    boxShadow: [
                      BoxShadow(
                        color: _green.withValues(alpha: 0.3),
                        blurRadius: 12,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.navigation_rounded,
                    color: Color(0xFF10231E),
                    size: 28,
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'دليل العراق',
                        style: TextStyle(
                          color: _textColor,
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
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
                  tooltip: widget.darkMode ? 'الوضع النهاري' : 'الوضع الليلي',
                  iconColor: _green,
                  onTap: widget.onThemeChanged,
                ),
              ],
            ),
            const SizedBox(height: 12),
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
          color: _speedKmh > _speedLimit ? Colors.red : _green,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: [
            BoxShadow(
              color: (_speedKmh > _speedLimit ? Colors.red : _green)
                  .withValues(alpha: 0.45),
              blurRadius: 16,
              spreadRadius: 2,
            ),
          ],
        ),
        child: const Icon(
          Icons.navigation_rounded,
          color: Color(0xFF10231E),
          size: 27,
        ),
      ),
    );
  }

  Widget _stat(IconData icon, String value, String label, {Color? color}) {
    return Column(
      children: [
        Icon(icon, color: color ?? _green, size: 23),
        const SizedBox(height: 6),
        Text(
          value,
          style: TextStyle(
            color: color ?? _textColor,
            fontSize: 15,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          style: TextStyle(color: _mutedColor, fontSize: 11),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _bottomPanel() {
    bool speedWarning = _speedKmh > _speedLimit;

    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: _panelColor,
          borderRadius: BorderRadius.circular(25),
          border: Border.all(
            color: speedWarning
                ? Colors.red.withValues(alpha: 0.5)
                : _green.withValues(alpha: 0.13),
            width: speedWarning ? 2 : 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.22),
              blurRadius: 24,
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
                    color: _green.withValues(alpha: 0.13),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    _navigating
                        ? Icons.navigation_rounded
                        : Icons.explore_rounded,
                    color: _green,
                    size: 25,
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _navigating
                            ? 'الملاحة نشطة'
                            : _destinationName.isNotEmpty
                                ? _destinationName
                                : 'وين وجهتك اليوم؟',
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
                    width: 21,
                    height: 21,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: _green,
                    ),
                  )
                else
                  Icon(Icons.circle, color: _green, size: 10),
              ],
            ),
            if (_routePoints.isNotEmpty || _navigating) ...[
              const SizedBox(height: 15),
              Divider(
                height: 1,
                color: _mutedColor.withValues(alpha: 0.2),
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
                      '${_remainingMinutes.round()} د',
                      'الوقت التقريبي',
                    ),
                  ),
                  Expanded(
                    child: _stat(
                      Icons.speed_rounded,
                      '${_speedKmh.round()}',
                      'كم/ساعة',
                      color: speedWarning ? Colors.red : null,
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 15),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _navigating ? _stopNavigation : _startNavigation,
                    icon: Icon(
                      _navigating
                          ? Icons.stop_circle_outlined
                          : Icons.navigation_rounded,
                    ),
                    label: Text(
                      _navigating ? 'إيقاف الملاحة' : 'ابدأ الملاحة',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor:
                          _navigating ? Colors.redAccent : _green,
                      foregroundColor: const Color(0xFF10231E),
                      minimumSize: const Size(0, 51),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                _roundButton(
                  icon: Icons.alt_route_rounded,
                  tooltip: 'احسب الطريق',
                  iconColor: _green,
                  onTap: _calculateRoute,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // خريطة OpenStreetMap مستقرة ومجانية
    const tileUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

    return Scaffold(
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
                onPositionChanged: (camera, hasGesture) {
                  if (hasGesture && _followingLocation && !_navigating) {
                    _followingLocation = false;
                  }
                },
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
                        color: const Color(0xFF1688FF).withValues(alpha: 0.25),
                      ),
                      Polyline(
                        points: _routePoints,
                        strokeWidth: 5,
                        color: const Color(0xFF1688FF),
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
                    // عرض التقارير التي تم الإبلاغ عنها على الخريطة
                    ..._activeReports.map((report) {
                      return Marker(
                        point: report.location,
                        width: 40,
                        height: 40,
                        child: GestureDetector(
                          onTap: () {
                            _showMessage('${report.type}: ${report.description}');
                          },
                          child: CircleAvatar(
                            backgroundColor: _getReportColor(report.type),
                            child: Icon(
                              _getReportIcon(report.type),
                              color: Colors.white,
                              size: 20,
                            ),
                          ),
                        ),
                      );
                    }),
                  ],
                ),
                RichAttributionWidget(
                  attributions: [
                    TextSourceAttribution('OpenStreetMap contributors'),
                  ],
                ),
              ],
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _topPanel(),
          ),
          Positioned(
            left: 14,
            bottom: 250,
            child: Column(
              children: [
                // زر الإبلاغ عن تنبيه على الطريق (Waze Report Button)
                _roundButton(
                  icon: Icons.add_alert_rounded,
                  tooltip: 'إبلاغ عن تنبيه',
                  iconColor: Colors.amber,
                  onTap: _showAddReportModal,
                ),
                const SizedBox(height: 11),
                _roundButton(
                  icon: Icons.my_location_rounded,
                  tooltip: 'موقعي',
                  iconColor: _green,
                  onTap: () async {
                    _followingLocation = true;
                    await _getCurrentLocation();
                    _mapController.move(
                      _currentLocation,
                      _navigating ? 17 : 16,
                    );
                  },
                ),
                const SizedBox(height: 11),
                _roundButton(
                  icon: Icons.add_rounded,
                  tooltip: 'تكبير',
                  onTap: () {
                    final camera = _mapController.camera;
                    _mapController.move(
                      camera.center,
                      (camera.zoom + 1).clamp(4, 19).toDouble(),
                    );
                  },
                ),
                const SizedBox(height: 11),
                _roundButton(
                  icon: Icons.remove_rounded,
                  tooltip: 'تصغير',
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
