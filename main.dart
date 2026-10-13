import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';

void main() => runApp(const DaleelApp());

class DaleelApp extends StatelessWidget {
  const DaleelApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'دليل العراق',
        locale: const Locale('ar'),
        supportedLocales: const [Locale('ar'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: ThemeData(colorSchemeSeed: const Color(0xFF087F5B), useMaterial3: true),
        home: const MapHome(),
      );
}

class MapHome extends StatefulWidget {
  const MapHome({super.key});
  @override
  State<MapHome> createState() => _MapHomeState();
}

class _MapHomeState extends State<MapHome> {
  final MapController _mapController = MapController();
  // نقطة بداية افتراضية في بغداد؛ يغيّرها زر موقعي.
  LatLng _center = const LatLng(33.3152, 44.3661);
  bool _locating = false;
  String _status = 'الخريطة جاهزة — اضغط زر الموقع لتحديد مكانك';

  Future<void> _goToMyLocation() async {
    setState(() { _locating = true; _status = 'جارٍ تحديد موقعك…'; });
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        setState(() => _status = 'فعّل خدمة الموقع GPS في هاتفك أولاً');
        return;
      }
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        setState(() => _status = 'اسمح للتطبيق بالوصول إلى الموقع من الإعدادات');
        return;
      }
      final position = await Geolocator.getCurrentPosition();
      final point = LatLng(position.latitude, position.longitude);
      setState(() { _center = point; _status = 'تم تحديد موقعك الحالي'; });
      _mapController.move(point, 15);
    } catch (_) {
      setState(() => _status = 'تعذر تحديد الموقع. تحقق من GPS والإنترنت.');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          body: Stack(children: [
            FlutterMap(
              mapController: _mapController,
              options: MapOptions(initialCenter: _center, initialZoom: 6.3),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.example.daleel_iraq',
                ),
                const RichAttributionWidget(
                  attributions: [TextSourceAttribution('© OpenStreetMap contributors')],
                ),
              ],
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(children: [
                  Material(
                    elevation: 4,
                    borderRadius: BorderRadius.circular(16),
                    child: TextField(
                      textInputAction: TextInputAction.search,
                      decoration: const InputDecoration(
                        hintText: 'ابحث عن مدينة أو مكان…',
                        prefixIcon: Icon(Icons.search),
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(vertical: 16),
                      ),
                      onSubmitted: (_) => ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('البحث عن الأماكن سنضيفه في الخطوة التالية')),
                      ),
                    ),
                  ),
                  const Spacer(),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FloatingActionButton(
                      heroTag: 'my-location',
                      onPressed: _locating ? null : _goToMyLocation,
                      child: _locating
                          ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.my_location),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.95), borderRadius: BorderRadius.circular(12)),
                    child: Text(_status, style: const TextStyle(fontSize: 14)),
                  ),
                ]),
              ),
            ),
          ]),
        ),
      );
}
