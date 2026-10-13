# دليل العراق — نموذج أولي

هذا مشروع Flutter مبدئي للأندرويد والآيفون، يعرض خريطة OpenStreetMap مع زر لتحديد الموقع الحالي وواجهة عربية.

## ما تحتاجه
- كمبيوتر Windows أو macOS أو Linux.
- تثبيت Flutter SDK وAndroid Studio. لبناء نسخة iPhone تحتاج جهاز Mac مع Xcode.
- اتصال إنترنت لتحميل حزم Flutter وخرائط OSM.

## التشغيل
1. فك ضغط الملف.
2. افتح مجلد `daleel_iraq` في VS Code أو Android Studio.
3. في الطرفية داخل المجلد نفّذ:
   ```sh
   flutter create .
   flutter pub get
   flutter run
   ```
4. عند اختبار الموقع، وافق على إذن الموقع وفعّل GPS.

## إعداد أذونات أندرويد
في `android/app/src/main/AndroidManifest.xml`، أضف قبل وسم `<application>`:
```xml
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
```

## حدود هذه النسخة
هذه بداية لعرض الخريطة والموقع فقط؛ لا تحتوي بعد على بحث فعلي أو تخطيط مسارات أو توجيه صوتي أو بيانات ازدحام مباشرة. خادم بلاطات OpenStreetMap العام له سياسة استخدام وحدود، وهو مناسب للتجربة لا لخدمة تجارية واسعة دون مزوّد مناسب.
