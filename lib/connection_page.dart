import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:permission_handler/permission_handler.dart';
import 'bluetooth_service.dart' as bt;
import 'control_page.dart';

class ConnectionPage extends StatefulWidget {
  const ConnectionPage({super.key});

  @override
  State<ConnectionPage> createState() => _ConnectionPageState();
}

class _ConnectionPageState extends State<ConnectionPage>
    with SingleTickerProviderStateMixin {
  final bt.BluetoothService _btService = bt.BluetoothService();
  List<BluetoothDevice> _pairedDevices = [];
  final List<BluetoothDiscoveryResult> _discoveredDevices = [];
  bool _isScanning = false;
  StreamSubscription<BluetoothDiscoveryResult>? _discoverySub;
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _btService.addListener(_onBtStateChanged);
    _requestPermissions();
  }

  @override
  void dispose() {
    _btService.removeListener(_onBtStateChanged);
    _discoverySub?.cancel();
    _pulseController.dispose();
    super.dispose();
  }

  void _onBtStateChanged() {
    if (!mounted) return;
    setState(() {});

    // Navigate to control page on successful connection
    if (_btService.connectionState == bt.ConnectionState.connected) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ControlPage(btService: _btService),
        ),
      );
    }

    // Show error snackbar
    if (_btService.connectionState == bt.ConnectionState.error) {
      _showSnackBar('Connection failed. Tap device to retry.', isError: true);
    }
  }

  Future<void> _requestPermissions() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    final denied = statuses.entries
        .where((e) => !e.value.isGranted)
        .map((e) => e.key.toString())
        .toList();

    if (denied.isNotEmpty && mounted) {
      _showSnackBar(
        'Permissions required: ${denied.join(", ")}',
        isError: true,
      );
    }

    // Load paired devices after permissions are granted
    _loadPairedDevices();
  }

  Future<void> _loadPairedDevices() async {
    final devices = await _btService.getPairedDevices();
    if (mounted) {
      setState(() => _pairedDevices = devices);
    }
  }

  void _startScan() {
    setState(() {
      _discoveredDevices.clear();
      _isScanning = true;
    });

    final stream = _btService.startDiscovery();
    if (stream == null) {
      setState(() => _isScanning = false);
      _showSnackBar('Could not start scanning', isError: true);
      return;
    }

    _discoverySub = stream.listen(
      (result) {
        if (!mounted) return;
        // Avoid duplicates
        final exists = _discoveredDevices
            .any((d) => d.device.address == result.device.address);
        if (!exists) {
          setState(() => _discoveredDevices.add(result));
        }
      },
      onDone: () {
        if (mounted) setState(() => _isScanning = false);
      },
      onError: (_) {
        if (mounted) setState(() => _isScanning = false);
      },
    );

    // Stop after 12 seconds
    Future.delayed(const Duration(seconds: 12), () {
      _discoverySub?.cancel();
      if (mounted) setState(() => _isScanning = false);
    });
  }

  void _connectToDevice(BluetoothDevice device) {
    if (_btService.connectionState == bt.ConnectionState.connecting) return;
    _btService.connect(device.address, device.name ?? 'Unknown');
  }

  void _showSnackBar(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.redAccent.shade700 : null,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isConnecting =
        _btService.connectionState == bt.ConnectionState.connecting;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0A0E21), Color(0xFF1A1F36), Color(0xFF0D1B2A)],
          ),
        ),
        child: SafeArea(
          child: Row(
            children: [
              // ---- Left panel: logo + status ----
              SizedBox(
                width: 260,
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      AnimatedBuilder(
                        animation: _pulseController,
                        builder: (_, child) {
                          final scale =
                              1.0 + 0.08 * _pulseController.value;
                          return Transform.scale(
                            scale: scale,
                            child: child,
                          );
                        },
                        child: Container(
                          width: 90,
                          height: 90,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: const RadialGradient(
                              colors: [
                                Color(0xFF00E5FF),
                                Color(0xFF006064),
                              ],
                            ),
                            boxShadow: [
                              BoxShadow(
                                color:
                                    const Color(0xFF00E5FF).withValues(alpha: 0.4),
                                blurRadius: 30,
                                spreadRadius: 5,
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.smart_toy_rounded,
                            size: 48,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        'ROBOT\nCONTROLLER',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 3,
                          color: Colors.white,
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(height: 12),
                      _buildStatusChip(),
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _isScanning || isConnecting
                              ? null
                              : _startScan,
                          icon: _isScanning
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Color(0xFF0A0E21),
                                  ),
                                )
                              : const Icon(Icons.bluetooth_searching),
                          label: Text(
                              _isScanning ? 'Scanning…' : 'Scan Devices'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // ---- Right panel: device list ----
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      vertical: 16, horizontal: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Paired section
                      _buildSectionHeader('PAIRED DEVICES'),
                      Expanded(
                        flex: 1,
                        child: _pairedDevices.isEmpty
                            ? const Center(
                                child: Text(
                                  'No paired devices found.\nPair ESP32_Robot in system settings first.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: Colors.white38),
                                ),
                              )
                            : ListView.builder(
                                itemCount: _pairedDevices.length,
                                itemBuilder: (_, i) => _buildDeviceTile(
                                    _pairedDevices[i], isPaired: true),
                              ),
                      ),
                      const Divider(color: Colors.white12, height: 1),

                      // Discovered section
                      _buildSectionHeader('DISCOVERED DEVICES'),
                      Expanded(
                        flex: 1,
                        child: _discoveredDevices.isEmpty
                            ? Center(
                                child: Text(
                                  _isScanning
                                      ? 'Searching…'
                                      : 'Tap "Scan" to find nearby devices.',
                                  style: const TextStyle(
                                      color: Colors.white38),
                                ),
                              )
                            : ListView.builder(
                                itemCount: _discoveredDevices.length,
                                itemBuilder: (_, i) => _buildDeviceTile(
                                    _discoveredDevices[i].device),
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 6),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 2,
          color: Colors.white38,
        ),
      ),
    );
  }

  Widget _buildStatusChip() {
    final cs = _btService.connectionState;
    Color color;
    String label;
    switch (cs) {
      case bt.ConnectionState.connected:
        color = Colors.greenAccent;
        label = 'Connected';
        break;
      case bt.ConnectionState.connecting:
        color = Colors.amberAccent;
        label = 'Connecting…';
        break;
      case bt.ConnectionState.error:
        color = Colors.redAccent;
        label = 'Error';
        break;
      case bt.ConnectionState.disconnected:
        color = Colors.white38;
        label = 'Disconnected';
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        ),
        const SizedBox(width: 8),
        Text(label, style: TextStyle(color: color, fontSize: 13)),
      ],
    );
  }

  Widget _buildDeviceTile(BluetoothDevice device, {bool isPaired = false}) {
    final name = device.name ?? 'Unknown';
    final address = device.address;
    final isConnecting =
        _btService.connectionState == bt.ConnectionState.connecting;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: Icon(
          isPaired ? Icons.bluetooth_connected : Icons.bluetooth,
          color: const Color(0xFF00E5FF),
        ),
        title: Text(
          name,
          style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          address,
          style: const TextStyle(color: Colors.white38, fontSize: 12),
        ),
        trailing: isConnecting
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.chevron_right, color: Colors.white24),
        onTap: isConnecting ? null : () => _connectToDevice(device),
      ),
    );
  }
}
