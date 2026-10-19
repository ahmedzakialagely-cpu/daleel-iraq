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

  bool _locating = false;
  bool _searching = false;

  String _status = 'دليل العراق جاهز';
  List<Map<String, dynamic>> _results = [];

  // تحديد الموقع الحقيقي
  Future<void> _goToMyLocation() async {
    if (_locating) return;

    setState(() {
      _locating = true;
      _status = 'جارٍ تحديد موقعك...';
    });

    try {
      final serviceEnabled =
          await Geolocator.isLocationServiceEnabled();

      if (!serviceEnabled) {
        _setStatus('فعّل خدمة الموقع GPS من إعدادات الهاتف');
        return;
      }

      LocationPermission permission =
          await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied) {
        _setStatus('لم تمنح التطبيق إذن الوصول إلى الموقع');
        return;
      }

      if (permission == LocationPermission.deniedForever) {
        _setStatus(
          'افتح إعدادات التطبيقات واسمح بالوصول إلى الموقع',
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

      if (!mounted) return;

      final point = LatLng(
        position.latitude,
        position.longitude,
      );

      setState(() {
        _myLocation = point;
        _center = point;
        _status = 'تم تحديد موقعك الحالي بنجاح';
      });

      _mapController.move(point, 16);
    } on TimeoutException {
      _setStatus(
        'تأخر GPS في تحديد موقعك. جرّب مكاناً مفتوحاً',
      );
    } catch (e) {
      _setStatus('تعذر تحديد الموقع: $e');
    } finally {
      if (mounted) {
        setState(() => _locating = false);
      }
    }
  }

  void _setStatus(String message) {
    if (!mounted) return;
    setState(() => _status = message);
  }

  // البحث الحقيقي عن الأماكن في العراق
  Future<void> _searchPlaces(String query) async {
    final text = query.trim();

    if (text.isEmpty) {
      setState(() {
        _results = [];
        _status = 'اكتب اسم المكان الذي تريد البحث عنه';
      });
      return;
    }

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
          'limit': '7',
          'addressdetails': '1',
          'accept-language': 'ar',
          'countrycodes': 'iq',
        },
      );

      final response = await http
          .get(
            uri,
            headers: {
              'User-Agent': 'DaleelIraq/1.0',
            },
          )
          .timeout(const Duration(seconds: 20));

      if (response.statusCode != 200) {
        throw Exception(
          'خدمة البحث غير متاحة حالياً '
          '(${response.statusCode})',
        );
      }

      final List<dynamic> data =
          jsonDecode(response.body) as List<dynamic>;

      final places = data
          .whereType<Map<String, dynamic>>()
          .where(
            (item) =>
                double.tryParse('${item['lat']}') != null &&
                double.tryParse('${item['lon']}') != null,
          )
          .toList();

      if (!mounted) return;

      setState(() {
        _results = places;
        _status = places.isEmpty
            ? 'لم نعثر على نتائج. جرّب اسماً آخر'
            : 'عُثر على ${places.length} نتيجة';
      });
    } on TimeoutException {
      _setStatus('انتهت مهلة البحث. تحقق من الإنترنت');
    } catch (e) {
      _setStatus('تعذر البحث: $e');
    } finally {
      if (mounted) {
        setState(() => _searching = false);
      }
    }
  }

  // الانتقال إلى المكان الذي اختاره المستخدم
  void _selectPlace(Map<String, dynamic> place) {
    final lat = double.parse('${place['lat']}');
    final lon = double.parse('${place['lon']}');

    final point = LatLng(lat, lon);
    final name = '${place['display_name'] ?? 'المكان'}';

    setState(() {
      _selectedPlace = point;
      _center = point;
      _results = [];
      _searchController.text = name.split(',').first;
      _status = 'المكان المحدد: ${name.split(',').first}';
    });

    _mapController.move(point, 16);
    FocusScope.of(context).unfocus();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        body: Stack(
          children: [
            FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: _center,
                initialZoom: 6.3,
              ),
              children: [
                TileLayer(
                  urlTemplate:
                      'https://tile.openstreetmap.org/'
                      '{z}/{x}/{y}.png',
                  userAgentPackageName:
                      'com.example.daleel_iraq',
                ),

                MarkerLayer(
                  markers: [
                    if (_myLocation != null)
                      Marker(
                        point: _myLocation!,
                        width: 44,
                        height: 44,
                        child: const Icon(
                          Icons.my_location,
                          color: Colors.blue,
                          size: 36,
                        ),
                      ),

                    if (_selectedPlace != null)
                      Marker(
                        point: _selectedPlace!,
                        width: 48,
                        height: 48,
                        child: const Icon(
                          Icons.location_pin,
                          color: Colors.red,
                          size: 46,
                        ),
                      ),
                  ],
                ),

                const RichAttributionWidget(
                  attributions: [
                    TextSourceAttribution(
                      '© OpenStreetMap contributors',
                    ),
                  ],
                ),
              ],
            ),

            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    Material(
                      elevation: 5,
                      borderRadius: BorderRadius.circular(16),
                      child: TextField(
                        controller: _searchController,
                        textInputAction: TextInputAction.search,
                        onSubmitted: _searchPlaces,
                        decoration: InputDecoration(
                          hintText: 'ابحث عن مكان في العراق...',
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon: IconButton(
                            onPressed: _searching
                                ? null
                                : () => _searchPlaces(
                                      _searchController.text,
                                    ),
                            icon: _searching
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child:
                                        CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.arrow_forward),
                          ),
                          border: InputBorder.none,
                          contentPadding:
                              const EdgeInsets.symmetric(
                            vertical: 16,
                            horizontal: 12,
                          ),
                        ),
                      ),
                    ),

                    if (_results.isNotEmpty)
                      Container(
                        margin: const EdgeInsets.only(top: 8),
                        constraints: const BoxConstraints(
                          maxHeight: 280,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: _results.length,
                          itemBuilder: (context, index) {
                            final place = _results[index];
                            final name =
                                '${place['display_name'] ?? ''}';

                            return ListTile(
                              leading: const Icon(
                                Icons.location_on,
                                color: Colors.red,
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

                    const Spacer(),

                    Align(
                      alignment: Alignment.centerLeft,
                      child: FloatingActionButton(
                        heroTag: 'my-location',
                        onPressed: _locating
                            ? null
                            : _goToMyLocation,
                        child: _locating
                            ? const CircularProgressIndicator()
                            : const Icon(Icons.my_location),
                      ),
                    ),

                    const SizedBox(height: 12),

                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(
                          alpha: 0.95,
                        ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        _status,
                        style: const TextStyle(fontSize: 14),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
