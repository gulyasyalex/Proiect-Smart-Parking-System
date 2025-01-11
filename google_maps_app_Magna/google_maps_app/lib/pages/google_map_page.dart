import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import 'package:google_map_app/constants.dart';
import 'package:google_map_app/models/weather_model.dart';
import 'package:google_map_app/services/weather_service.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:location/location.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:url_launcher/url_launcher.dart';




Set<Marker> markers = {};

class GoogleMapPage extends StatefulWidget {
  const GoogleMapPage({super.key});

  @override
  State<GoogleMapPage> createState() => _GoogleMapPageState();
}

class _MarkerPainter extends CustomPainter {
  final int number;

  _MarkerPainter(this.number);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    final borderPaint = Paint()
      ..color = Colors.red
      ..style = PaintingStyle.stroke
      ..strokeWidth = 11; // Adjust the width of the border as needed

    final shadowPaint = Paint()
      ..color = Colors.grey.withOpacity(0.5)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);

    // Define the size of the circle and the notch
    final double circleRadius = size.width / 3;
    final double borderRadius = size.width / 3;
    final double notchHeight = 60;
    final double notchWidth = 50;

    // Draw the shadow for the circle and notch
    final shadowPath = Path()
      ..addOval(Rect.fromCircle(center: Offset(size.width / 2, borderRadius+ 20), radius: borderRadius))
      ..moveTo(size.width / 2 - notchWidth / 2, borderRadius * 2 + 50)
      ..lineTo(size.width / 2, borderRadius * 2 + notchHeight)
      ..lineTo(size.width / 2 + notchWidth / 2, borderRadius * 2)
      ..close();
    //canvas.drawPath(shadowPath, shadowPaint);

    // Draw the red border (slightly larger circle)
    final borderPath = Path()
      ..addOval(Rect.fromCircle(center: Offset(size.width / 2, borderRadius + 20), radius: borderRadius));
    canvas.drawPath(borderPath, borderPaint);

    // Draw the circle
    final circlePath = Path()
      ..addOval(Rect.fromCircle(center: Offset(size.width / 2, borderRadius + 20), radius: borderRadius - 10));
    canvas.drawPath(circlePath, paint);

    final notchPaint = Paint()
      ..color = Colors.red
      ..style = PaintingStyle.fill;

    // Draw the notch
    final notchPath = Path()
    //..moveTo(size.width / 2 - notchWidth / 2, borderRadius * 2)
      ..moveTo(size.width / 2 - notchWidth / 2, borderRadius * 2 + 20)
      ..lineTo(size.width / 2, borderRadius * 2 + notchHeight)
      ..lineTo(size.width / 2 + notchWidth / 2 , borderRadius * 2 + 20)
      ..close();
    canvas.drawPath(notchPath, notchPaint);

    // Draw the number inside the circle
    final textPainter = TextPainter(
      text: TextSpan(
        text: number.toString(),
        style: TextStyle(
          fontSize: 70, // Adjust font size as needed
          fontWeight: FontWeight.bold,
          color: Colors.black,
        ),
      ),
      textDirection: TextDirection.ltr,
    );

    textPainter.layout();
    textPainter.paint(
      canvas,
      Offset(size.width / 2 - textPainter.width / 2, borderRadius + 20 - textPainter.height / 2),
    );
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}


class _GoogleMapPageState extends State<GoogleMapPage> {
  final locationController = Location();
  bool lightsOn = false;

  static const agnaPark = LatLng(45.766237541629664, 21.23028715374242);
  static const exempleMarker = LatLng(45.766237541629664, 21.23028715374242);

  LatLng? currentPosition;
  Map<PolylineId, Polyline> polylines = {};

  final _weatherService = WeatherService();
  Weather? _weather;
  MqttServerClient? mqttClient;
  int freeParkingSpaces = 0; // Default value
  OverlayEntry? _overlayEntry;

  bool _isSwitchOn = false; // Starea trebuie să fie o variabilă de instanță

  void _toggleLights() {
    if (_isSwitchOn) {
      _sendMessage('lights_off');
    } else {
      _sendMessage('lights_on');
    }
    setState(() {
      _isSwitchOn = !_isSwitchOn;
    });
  }


  _fetchWeather() async{
    String cityName = await _weatherService.getCurrentCity(agnaPark);

    try{
      final weather = await _weatherService.getWeather(cityName);
      setState(() {
        _weather = weather;
      });
    }catch (e){
      print(e);
    }
  }


  Future<void> _connectMQTT() async {
    //mqttClient = MqttServerClient('127.0.0.1', '1883');
    //mqttClient = MqttServerClient('10.0.2.2', '');
    mqttClient = MqttServerClient('172.20.10.2', '');
    mqttClient!.logging(on: true);

    mqttClient!.onConnected = _onConnected;
    mqttClient!.onDisconnected = _onDisconnected;
    mqttClient!.onSubscribed = _onSubscribed;

    final connMessage = MqttConnectMessage()
        .withClientIdentifier('flutter_client')
        .startClean()
        .withWillQos(MqttQos.atLeastOnce);
    mqttClient!.connectionMessage = connMessage;

    try {
      await mqttClient!.connect();
    } catch (e) {
      print('Exception: $e');
      _disconnectMQTT();
    }

    mqttClient!.updates?.listen((List<MqttReceivedMessage<MqttMessage>> c) {
      final MqttPublishMessage recMess = c[0].payload as MqttPublishMessage;
      final String pt = MqttPublishPayload.bytesToStringAsString(recMess.payload.message);
      print('Received message:$pt from topic: ${c[0].topic}>');

      final matches = RegExp(r'park_spaces:(\d+)/(\d+)').firstMatch(pt);
      if (matches != null) {
        final occupiedSpaces = int.parse(matches.group(1)!);
        final totalSpaces = int.parse(matches.group(2)!);
        setState(() {
          freeParkingSpaces = totalSpaces - occupiedSpaces;
          _updateMarker();
        });
      }
      else if (c[0].topic == 'agna_park_topic') {
        if (pt == 'lights_on') {
          setState(() {
            lightsOn = true;
          });
        } else if (pt == 'lights_off') {
          setState(() {
            lightsOn = false;
          });
        }
      }

    });

    mqttClient!.subscribe('agna_park_topic', MqttQos.atLeastOnce);
    //mqttClient!.subscribe('agna_park_lights', MqttQos.atLeastOnce);
  }

  void _disconnectMQTT() {
    mqttClient?.disconnect();
  }

  void _onConnected() {
    print('Connected to MQTT broker');
  }

  void _onDisconnected() {
    print('Disconnected from MQTT broker');
  }

  void _onSubscribed(String topic) {
    print('Subscribed to $topic');
  }

  void _sendMessage(String message) {
    final builder = MqttClientPayloadBuilder();
    builder.addString(message);
    mqttClient!.publishMessage('agna_park_topic', MqttQos.atLeastOnce, builder.payload!);
    mqttClient!.publishMessage('agna_park_lights', MqttQos.atLeastOnce, builder.payload!);
  }



  Future<void> _updateMarker() async {
    final customMarker = await _getMarkerWithNumber(freeParkingSpaces);
    setState(() {
      markers.removeWhere((marker) => marker.markerId.value == 'customMarker');
      markers.add(Marker(
        markerId: MarkerId('customMarker'),
        icon: BitmapDescriptor.fromBytes(customMarker as Uint8List),
        position: agnaPark,
        onTap: () {
          showOverlay(context);
        },
      ));
    });
  }

  Future<Uint8List> _getMarkerWithNumber(int number) async {
    final pictureRecorder = ui.PictureRecorder();
    final canvas = Canvas(pictureRecorder);

    final size = const Size(250, 250); // Adjust size as needed

    final painter = _MarkerPainter(number);
    painter.paint(canvas, size);

    final picture = pictureRecorder.endRecording();
    final img = await picture.toImage(size.width.toInt(), size.height.toInt());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);

    return byteData!.buffer.asUint8List();
  }

  Future<void> addCustomMarker(int number) async {
    final customMarker = await _getMarkerWithNumber(number);
    setState(() {
      markers.add(Marker(
        markerId: MarkerId('customMarker$number'),
        icon: BitmapDescriptor.fromBytes(customMarker as Uint8List),
        position: agnaPark,
      ));
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance
        .addPostFrameCallback((_) async => await initializeMap());

    // Fetch weather data
    _fetchWeather();
    // Connect Mqtt
    print("ok trying mqtt");
    _connectMQTT();
  }

  Future<void> initializeMap() async {
    await fetchLocationUpdates();
    final coordinates = await fetchPolylinePoints();
    generatePolyLineFromPoints(coordinates);
    /*markers.add(Marker(
      markerId: MarkerId('sourceLocation'),
      icon: BitmapDescriptor.defaultMarker,
      position: agnaPark,
    ));*/

    await _updateMarker();
    //await addCustomMarker(10); // Pass the number you want to display
  }

  @override
  void dispose() {
    _disconnectMQTT();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Stack(
      children: [
        currentPosition == null
            ? const Center(child: CircularProgressIndicator())
            : GoogleMap(
          initialCameraPosition: const CameraPosition(
            target: agnaPark,
            zoom: 15,
          ),
          markers: markers,
          zoomControlsEnabled: false,
          polylines: Set<Polyline>.of(polylines.values),
        ),

        Positioned(
          top: 70, // Adjust this value to position the navigation bar higher
          left: 24,
          right: 24,
          child: Container(
            height: 70,
            padding: EdgeInsets.all(12),
            decoration: BoxDecoration(
              gradient: getGradient(0),
              borderRadius: BorderRadius.all(Radius.circular(24)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.25), // Shadow color with opacity
                  spreadRadius: 2, // Spread radius
                  blurRadius: 8, // Blur radius
                  offset: Offset(0, 4), // Shadow position
                ),
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                Text(
                  "AGNA Park",
                  style: TextStyle(
                    fontSize: 27, // Adjust the font size for the city name
                    color: Colors.black, // Optional: Change the text color
                  ),
                ),
                Text(
                  " | ",
                  style: TextStyle(
                    fontSize: 30, // Adjust the font size for the city name
                    color: Colors.black, // Optional: Change the text color
                  ),
                ),
                GestureDetector(
                  onTap: () => showInfoOverlay(context),
                  child: Container(
                    child: Image.asset(
                      'assets/icons/infoWhite.png',
                      width: 30,
                      height: 30,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Positioned(
          bottom: 50, // Adjust this value to position the navigation bar higher
          left: 24,
          right: 24,
          child: Container(
            height: 70,
            padding: EdgeInsets.all(12),
            decoration: BoxDecoration(
              gradient: getGradient(_weather?.temperature ?? 0),
              borderRadius: BorderRadius.all(Radius.circular(24)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.35), // Shadow color with opacity
                  spreadRadius: 2, // Spread radius
                  blurRadius: 8, // Blur radius
                  offset: Offset(0, 4), // Shadow position
                ),
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _weather?.cityName != null
                    ? Text(
                  _weather!.cityName,
                  style: TextStyle(
                    fontSize: 32,
                    color: Colors.black,
                  ),
                )
                    : Row(
                  children: [
                    SizedBox(width: 8),
                    SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                      ),
                    ),
                  ],
                ),
                Text(
                  " | ",
                  style: TextStyle(
                    fontSize: 30,
                    color: Colors.black,
                  ),
                ),
                _weather?.temperature != null
                    ? Text(
                  '${_weather!.temperature!.round()}°C',
                  style: TextStyle(
                    fontSize: 30,
                    color: Colors.black,
                  ),
                )
                    : SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  LinearGradient getGradient(double temperature) {
    if (temperature <= 5) {
      return LinearGradient(
        colors: [Colors.white.withOpacity(0.9),Colors.white.withOpacity(1), Colors.white.withOpacity(0.9)],
        stops: [0.0, 0.5, 1.0],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      );
    } else if (temperature > 5 && temperature <= 22) {
      return LinearGradient(
        colors: [Colors.white.withOpacity(0.9),Colors.white.withOpacity(1), Colors.blueAccent.withOpacity(0.9)],
        stops: [0.0, 0.5, 1.0],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      );
    } else if (temperature > 22 && temperature <= 35) {
      return LinearGradient(
        colors: [Colors.white.withOpacity(0.9),Colors.white.withOpacity(1), Colors.orangeAccent.withOpacity(0.9)],
        stops: [0.0, 0.5, 1.0],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      );
    } else {
      return LinearGradient(
        colors: [Colors.black.withOpacity(0.9),Colors.black.withOpacity(1), Colors.redAccent.withOpacity(0.9)],
        stops: [0.0, 0.5, 1.0],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      );
    }
  }

  Future<void> fetchLocationUpdates() async {
    bool serviceEnabled;
    PermissionStatus permissionGranted;

    serviceEnabled = await locationController.serviceEnabled();
    if (serviceEnabled) {
      serviceEnabled = await locationController.requestService();
    } else {
      return;
    }

    permissionGranted = await locationController.hasPermission();
    if (permissionGranted == PermissionStatus.denied) {
      permissionGranted = await locationController.requestPermission();
      if (permissionGranted != PermissionStatus.granted) {
        return;
      }
    }

    locationController.onLocationChanged.listen((currentLocation) {
      if (currentLocation.latitude != null &&
          currentLocation.longitude != null) {
        setState(() {
          currentPosition = LatLng(
            currentLocation.latitude!,
            currentLocation.longitude!,
          );
        });
      }
    });
  }

  Future<List<LatLng>> fetchPolylinePoints() async {
    final polylinePoints = PolylinePoints();

    final result = await polylinePoints.getRouteBetweenCoordinates(
      googleMapsApiKey,
      PointLatLng(agnaPark.latitude, agnaPark.longitude),
      PointLatLng(exempleMarker.latitude, exempleMarker.longitude),
    );

    if (result.points.isNotEmpty) {
      return result.points
          .map((point) => LatLng(point.latitude, point.longitude))
          .toList();
    } else {
      debugPrint(result.errorMessage);
      return [];
    }
  }

  Future<void> generatePolyLineFromPoints(
      List<LatLng> polylineCoordinates) async {
    const id = PolylineId('polyline');

    final polyline = Polyline(
      polylineId: id,
      color: Colors.blueAccent,
      points: polylineCoordinates,
      width: 5,
    );

    setState(() => polylines[id] = polyline);
  }
  void showOverlay(BuildContext context) {
    if (_overlayEntry != null) return;

    _overlayEntry = OverlayEntry(
      builder: (context) => Stack(
        children: [
          GestureDetector(
            onTap: hideOverlay,
            child: Container(
              color: Colors.black54,
              width: MediaQuery.of(context).size.width,
              height: MediaQuery.of(context).size.height,
            ),
          ),
          Positioned(
            bottom: 10,
            left: 10,
            right: 10,
            child: Container(
              height: MediaQuery.of(context).size.height * 2 / 3,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(15),
              ),
              child: Padding(
                padding: const EdgeInsets.only(left: 30, right: 30, bottom: 30),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    Align(
                      alignment: Alignment.topRight,
                      child: IconButton(
                        icon: Icon(Icons.close),
                        onPressed: hideOverlay,
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Image.asset(
                          'assets/icons/logo.png',
                          width: 200,
                          height: 100,
                        ),
                        SizedBox(width: 5),
                      ],
                    ),
                    Divider(
                      color: Colors.grey.withOpacity(0.8),
                      thickness: 2,
                      indent: 20,
                      endIndent: 20,
                    ),
                    Column(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Text(
                          'Free Parking Spaces',
                          style: TextStyle(
                            fontSize: 18,
                            decoration: TextDecoration.none,
                            color: Colors.black,
                          ),
                        ),
                        SizedBox(height: 30),
                        Padding(
                          padding: const EdgeInsets.only(left: 30, right: 20),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              Text(
                                '$freeParkingSpaces',
                                style: TextStyle(
                                  fontSize: 35,
                                  decoration: TextDecoration.none,
                                  color: freeParkingSpaces > 0 ? Colors.green : Colors.red,
                                ),
                              ),
                              Text(
                                'x',
                                style: TextStyle(
                                  fontSize: 25,
                                  decoration: TextDecoration.none,
                                  color: Colors.black,
                                ),
                              ),
                              Image.asset(
                                freeParkingSpaces == 0
                                    ? 'assets/icons/car.png'
                                    : 'assets/icons/carGreen.png',
                                width: 150,
                                height: 100,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    Divider(
                      color: Colors.grey.withOpacity(0.8),
                      thickness: 2,
                      indent: 20,
                      endIndent: 20,
                    ),
                    Column(
                      children: [
                        Text(
                          'Piața Consiliul Europei nr.2C',
                          style: TextStyle(
                            decoration: TextDecoration.none,
                            fontSize: 16,
                            color: Colors.grey,
                          ),
                        ),
                        Text(
                          'Timișoara',
                          style: TextStyle(
                            decoration: TextDecoration.none,
                            fontSize: 16,
                            color: Colors.grey,
                          ),
                        ),
                        SizedBox(height: 10),
                        GestureDetector(
                          onTap: () {
                            launchUrl(Uri.parse("https://maps.app.goo.gl/tLjsHA2vzegDEsBq8"));
                          },
                          child: Text(
                            'Open in Google Maps',
                            style: TextStyle(
                              decoration: TextDecoration.none,
                              fontSize: 16,
                              color: Colors.green,
                            ),
                          ),
                        ),
                      ],
                    ),
                    Divider(
                      color: Colors.grey.withOpacity(0.8),
                      thickness: 2,
                      indent: 20,
                      endIndent: 20,
                    ),
                    Text(
                      'Opened 24/7',
                      style: TextStyle(
                        fontSize: 16,
                        decoration: TextDecoration.none,
                        color: Colors.black,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );

    Overlay.of(context).insert(_overlayEntry!);
  }

  void hideOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  OverlayEntry? _infoOverlayEntry;


  void showInfoOverlay(BuildContext context) {
    if (_infoOverlayEntry != null) return;
    _infoOverlayEntry = OverlayEntry(
      builder: (context) => Stack(
        children: [
          GestureDetector(
            onTap: hideInfoOverlay,
            child: Container(
              color: Colors.black54,
              width: MediaQuery.of(context).size.width,
              height: MediaQuery.of(context).size.height,
            ),
          ),
          Positioned(
            bottom: 10,
            left: 10,
            right: 10,
            child: Container(
              height: MediaQuery.of(context).size.height * 2 / 3,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(15),
              ),
              child: Padding(
                padding: const EdgeInsets.only(left: 30, right: 30, bottom: 30),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    Align(
                      alignment: Alignment.topRight,
                      child: IconButton(
                        icon: Icon(Icons.close),
                        onPressed: hideInfoOverlay,
                      ),
                    ),
                    Text(
                      'Info',
                      style: TextStyle(
                        decoration: TextDecoration.none,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Colors.black,
                      ),
                    ),
                    Divider(
                      color: Colors.grey.withOpacity(0.8),
                      thickness: 2,
                      indent: 15,
                      endIndent: 15,
                    ),
                    Text(
                      'Dream Team:',
                      style: TextStyle(
                        decoration: TextDecoration.none,
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: Colors.green,
                      ),
                    ),
                    Text(
                      'Maria Dicu\n'
                          'Alex Gulyasy\n'
                          'Andrei Duduman\n'
                          'Robert Negre',
                      style: TextStyle(
                        decoration: TextDecoration.none,
                        fontSize: 15,
                        color: Colors.black,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    Divider(
                      color: Colors.grey.withOpacity(0.8),
                      thickness: 2,
                      indent: 20,
                      endIndent: 20,
                    ),
                    Text(
                      'Tel.:',
                      style: TextStyle(
                        decoration: TextDecoration.none,
                        fontSize: 14,
                        color: Colors.green,
                      ),
                    ),
                    Text(
                      ' +40 736 891 363',
                      style: TextStyle(
                        decoration: TextDecoration.none,
                        fontSize: 14,
                        color: Colors.black,
                      ),
                    ),
                    Divider(
                      color: Colors.grey.withOpacity(0.8),
                      thickness: 2,
                      indent: 20,
                      endIndent: 20,
                    ),
                    Text(
                      'Email:',
                      style: TextStyle(
                        decoration: TextDecoration.none,
                        fontSize: 14,
                        color: Colors.green,
                      ),
                    ),
                    Text(
                      ' agnapark@gmail.com',
                      style: TextStyle(
                        decoration: TextDecoration.none,
                        fontSize: 14,
                        color: Colors.black,
                      ),
                    ),
                    // Adăugarea butonului ON/OFF
                    TextButton(
                      style: ButtonStyle(
                        foregroundColor: MaterialStateProperty.all<Color>(Colors.white),
                        backgroundColor: MaterialStateProperty.resolveWith<Color>((Set<MaterialState> states) {
                          if (states.contains(MaterialState.pressed)) {
                            return _isSwitchOn ? Colors.green.shade700 : Colors.red.shade700;
                          }
                          return _isSwitchOn ? Colors.green : Colors.red;
                        }),
                        padding: MaterialStateProperty.all<EdgeInsets>(EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0)),
                        shape: MaterialStateProperty.all<RoundedRectangleBorder>(
                          RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10.0),
                          ),
                        ),
                      ),
                      onPressed: () {
                        _toggleLights();
                      },
                      child: Text(
                        'TAP HERE',
                        key: Key('switchText'),
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
    Overlay.of(context).insert(_infoOverlayEntry!);
  }



  void hideInfoOverlay() {
    _infoOverlayEntry?.remove();
    _infoOverlayEntry = null;
  }




}