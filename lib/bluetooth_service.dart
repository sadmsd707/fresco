import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';

/// Manages Bluetooth SPP connection and command sending for RampBot.
///
/// Protocol (matches the ESP32 firmware):
///   Drive: single chars F/B/L/R/G/I/H/J/S  (no newline needed)
///   Speed: 0-9, q
///   Servo: a{0-180}\n  b{0-180}\n  c{0-180}\n  d{0-180}\n
///   Joystick drive: j{x},{y}\n   x=turn y=throttle, each -100..100
///   Arm home: P
class BluetoothService extends ChangeNotifier {
  BluetoothConnection? _connection;
  BluetoothState _adapterState = BluetoothState.UNKNOWN;
  ConnectionState _connectionState = ConnectionState.disconnected;
  String _lastCommand = '';
  String? _connectedDeviceName;
  StreamSubscription<Uint8List>? _inputSubscription;

  // --- Getters ---
  BluetoothState get adapterState => _adapterState;
  ConnectionState get connectionState => _connectionState;
  String get lastCommand => _lastCommand;
  String? get connectedDeviceName => _connectedDeviceName;
  bool get isConnected => _connectionState == ConnectionState.connected;

  BluetoothService() {
    _initAdapterState();
  }

  Future<void> _initAdapterState() async {
    try {
      _adapterState = await FlutterBluetoothSerial.instance.state;
      notifyListeners();

      FlutterBluetoothSerial.instance
          .onStateChanged()
          .listen((BluetoothState state) {
        _adapterState = state;
        notifyListeners();
      });
    } catch (e) {
      debugPrint('Adapter state error: $e');
    }
  }

  /// Returns list of bonded (paired) devices.
  Future<List<BluetoothDevice>> getPairedDevices() async {
    try {
      return await FlutterBluetoothSerial.instance.getBondedDevices();
    } catch (e) {
      debugPrint('Error getting paired devices: $e');
      return [];
    }
  }

  /// Starts discovery of nearby Bluetooth devices.
  Stream<BluetoothDiscoveryResult>? startDiscovery() {
    try {
      return FlutterBluetoothSerial.instance.startDiscovery();
    } catch (e) {
      debugPrint('Discovery error: $e');
      return null;
    }
  }

  /// Connect to a device by address.
  Future<bool> connect(String address, String name) async {
    if (_connectionState == ConnectionState.connecting) return false;

    _connectionState = ConnectionState.connecting;
    _connectedDeviceName = name;
    notifyListeners();

    try {
      _connection = await BluetoothConnection.toAddress(address)
          .timeout(const Duration(seconds: 10));

      _connectionState = ConnectionState.connected;
      notifyListeners();

      // Listen for incoming data (and disconnects)
      _inputSubscription = _connection!.input?.listen(
        (Uint8List data) {
          debugPrint('Received: ${utf8.decode(data)}');
        },
        onDone: () {
          debugPrint('BT connection closed by remote.');
          _handleDisconnect();
        },
        onError: (error) {
          debugPrint('BT input error: $error');
          _handleDisconnect();
        },
        cancelOnError: true,
      );

      return true;
    } on TimeoutException {
      _connectionState = ConnectionState.error;
      notifyListeners();
      return false;
    } catch (e) {
      debugPrint('Connection error: $e');
      _connectionState = ConnectionState.error;
      notifyListeners();
      return false;
    }
  }

  /// Disconnect from current device.
  Future<void> disconnect() async {
    _inputSubscription?.cancel();
    _inputSubscription = null;

    try {
      await _connection?.close();
    } catch (_) {}

    _connection = null;
    _connectionState = ConnectionState.disconnected;
    _connectedDeviceName = null;
    _lastCommand = '';
    notifyListeners();
  }

  void _handleDisconnect() {
    _inputSubscription?.cancel();
    _inputSubscription = null;
    _connection = null;
    _connectionState = ConnectionState.disconnected;
    notifyListeners();
  }

  /// Send raw bytes (single-char commands like F, B, S — no newline).
  void sendChar(String char_) {
    if (_connection == null || !isConnected) return;
    _sendRaw(char_);
    _lastCommand = char_;
    notifyListeners();
  }

  /// Send a newline-terminated line command (servo/joystick).
  void sendLine(String line) {
    if (_connection == null || !isConnected) return;
    _sendRaw('$line\n');
    _lastCommand = line;
    notifyListeners();
  }

  void _sendRaw(String data) {
    try {
      final bytes = utf8.encode(data);
      _connection!.output.add(Uint8List.fromList(bytes));
      _connection!.output.allSent.catchError((e) {
        debugPrint('Send error: $e');
        _handleDisconnect();
      });
    } catch (e) {
      debugPrint('Send error: $e');
      _handleDisconnect();
    }
  }

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }
}

enum ConnectionState {
  disconnected,
  connecting,
  connected,
  error,
}
