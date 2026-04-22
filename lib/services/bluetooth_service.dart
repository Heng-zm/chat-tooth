import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;
import 'package:rxdart/rxdart.dart';
import 'package:uuid/uuid.dart';
import '../platform/app_platform.dart';
import 'encryption_service.dart';
import '../models/message_model.dart';
import '../models/device_model.dart';

// Conditional import so dart:io isn't referenced on Web
import 'bluetooth_classic_stub.dart'
    if (dart.library.io) 'bluetooth_classic_android.dart';

// ─────────────────────────────────────────────────────────────────────────────
// BLE service / characteristic UUIDs (custom)
// ─────────────────────────────────────────────────────────────────────────────
const _kServiceUuid = '6E400001-B5A3-F393-E0A9-E50E24DCCA9E';
const _kTxUuid = '6E400003-B5A3-F393-E0A9-E50E24DCCA9E';
const _kRxUuid = '6E400002-B5A3-F393-E0A9-E50E24DCCA9E';

enum BtConnectionState {
  disconnected,
  scanning,
  connecting,
  connected,
  error,
}

class BluetoothService extends ChangeNotifier {
  final EncryptionService _encryption;
  final _uuid = const Uuid();

  ClassicBluetoothHelper? _classic;

  fbp.BluetoothDevice? _bleDevice;
  fbp.BluetoothCharacteristic? _bleRx;
  // REMOVED: Unused _bleTx field per linter suggestion

  StreamSubscription? _bleNotifySubscription;
  StreamSubscription? _bleScanSubscription;
  StreamSubscription? _bleConnectionStateSubscription;

  BtConnectionState _state = BtConnectionState.disconnected;
  final List<BTDevice> _pairedDevices = [];
  final List<BTDevice> _discovered = [];
  final List<Message> _messages = [];
  String? _connectedDeviceName;
  String? _connectedDeviceAddress;
  String? _errorMessage;
  bool _isDiscovering = false;
  bool _disposed = false;

  final List<int> _byteBuffer = [];

  final _discoverySubject = PublishSubject<BTDevice>();
  StreamSubscription? _discoveryDebounce;

  BluetoothService({EncryptionService? encryption})
      : _encryption = encryption ?? EncryptionService() {
    if (AppPlatform.supportsClassicBluetooth) {
      _classic = ClassicBluetoothHelper();
    }

    _discoveryDebounce = _discoverySubject
        .throttleTime(const Duration(milliseconds: 250))
        .listen(_addOrUpdateDiscovered);
  }

  // ── Public Getters ────────────────────────────────────────────────────────
  BtConnectionState get state => _state;
  List<BTDevice> get pairedDevices => List.unmodifiable(_pairedDevices);

  List<BTDevice> get discovered {
    final list = List<BTDevice>.from(_discovered);
    list.sort((a, b) => (b.rssi ?? -100).compareTo(a.rssi ?? -100));
    return List.unmodifiable(list);
  }

  List<Message> get messages => List.unmodifiable(_messages);
  String? get connectedDeviceName => _connectedDeviceName;
  String? get connectedDeviceAddress => _connectedDeviceAddress;
  String? get errorMessage => _errorMessage;
  bool get isDiscovering => _isDiscovering;
  bool get isConnected => _state == BtConnectionState.connected;
  EncryptionService get encryptionService => _encryption;

  // ═════════════════════════════════════════════════════════════════════════
  // INITIALISATION
  // ═════════════════════════════════════════════════════════════════════════

  Future<void> initialize() async {
    try {
      debugPrint('[BT] Initializing platform services...');
      if (AppPlatform.supportsClassicBluetooth) {
        await _classic!.ensureEnabled();
        await _loadClassicPaired();
      }
      if (AppPlatform.supportsBLE) {
        await _checkBleAdapter();
      }
    } catch (e) {
      _setError('Bluetooth init failed: $e');
    }
  }

  Future<void> _checkBleAdapter() async {
    try {
      final state = await fbp.FlutterBluePlus.adapterState.first;
      debugPrint('[BT] BLE Adapter state: $state');

      if (state != fbp.BluetoothAdapterState.on && AppPlatform.isAndroid) {
        await fbp.FlutterBluePlus.turnOn();
      }
    } catch (e) {
      debugPrint('[BT] BLE Adapter check failed: $e');
    }
  }

  Future<void> _loadClassicPaired() async {
    final pairs = await _classic!.getBondedDevices();
    _pairedDevices
      ..clear()
      ..addAll(pairs);
    _notify();
  }

  // ═════════════════════════════════════════════════════════════════════════
  // DISCOVERY
  // ═════════════════════════════════════════════════════════════════════════

  Future<void> startDiscovery() async {
    if (_isDiscovering) await stopDiscovery();
    _discovered.clear();
    _isDiscovering = true;
    _setState(BtConnectionState.scanning);

    if (AppPlatform.supportsClassicBluetooth) {
      _classic!.startDiscovery(
        onFound: (d) => _discoverySubject.add(d),
        onDone: () {
          if (!AppPlatform.supportsBLE) {
            _stopScanUI();
          }
        },
        onError: (e) => _setError('Classic scan error: $e'),
      );
    }

    if (AppPlatform.supportsBLE) {
      try {
        await fbp.FlutterBluePlus.startScan(
          timeout: const Duration(seconds: 15),
          androidUsesFineLocation: true,
        );

        _bleScanSubscription =
            fbp.FlutterBluePlus.scanResults.listen((results) {
          for (final r in results) {
            _discoverySubject.add(BTDevice(
              name: r.device.platformName.isNotEmpty
                  ? r.device.platformName
                  : 'Unknown Device',
              address: r.device.remoteId.str,
              type: 'BLE',
              rssi: r.rssi,
              isBLE: true,
            ));
          }
        });

        fbp.FlutterBluePlus.isScanning
            .where((s) => !s)
            .first
            .then((_) => _stopScanUI());
      } catch (e) {
        _stopScanUI();
        _setError('BLE scan failed: $e');
      }
    }
  }

  void _stopScanUI() {
    _isDiscovering = false;
    if (_state == BtConnectionState.scanning) {
      _setState(BtConnectionState.disconnected);
    }
    _notify();
  }

  Future<void> stopDiscovery() async {
    if (AppPlatform.supportsClassicBluetooth) {
      await _classic!.cancelDiscovery();
    }
    if (AppPlatform.supportsBLE) {
      await _bleScanSubscription?.cancel();
      _bleScanSubscription = null;
      if (fbp.FlutterBluePlus.isScanningNow) {
        await fbp.FlutterBluePlus.stopScan();
      }
    }
    _stopScanUI();
  }

  void _addOrUpdateDiscovered(BTDevice d) {
    final idx = _discovered.indexWhere((x) => x.address == d.address);
    if (idx >= 0) {
      _discovered[idx] = d;
    } else {
      _discovered.add(d);
    }
    _notify();
  }

  // ═════════════════════════════════════════════════════════════════════════
  // CONNECTION
  // ═════════════════════════════════════════════════════════════════════════

  Future<void> connectToDevice(BTDevice device) async {
    if (_state == BtConnectionState.connecting) return;

    await stopDiscovery();
    await disconnect();

    _setState(BtConnectionState.connecting);
    _messages.clear();

    try {
      if (!device.isBLE && AppPlatform.supportsClassicBluetooth) {
        await _connectClassic(device);
      } else {
        await _connectBLE(device);
      }
    } catch (e) {
      await disconnect();
      _setError('Connection failed: $e');
    }
  }

  Future<void> _connectClassic(BTDevice device) async {
    await _classic!.connect(
      address: device.address,
      onData: _onRawData,
      onDone: () => disconnect(),
      onError: (e) {
        if (isConnected) {
          _setError('Lost connection: $e');
          disconnect();
        }
      },
    );
    _onConnectedSuccess(device);
  }

  Future<void> _connectBLE(BTDevice device) async {
    final bleDevice = fbp.BluetoothDevice.fromId(device.address);
    await bleDevice.connect(timeout: const Duration(seconds: 15));

    if (AppPlatform.isAndroid) {
      await bleDevice.requestMtu(512);
    }

    _bleConnectionStateSubscription = bleDevice.connectionState.listen((s) {
      if (s == fbp.BluetoothConnectionState.disconnected && isConnected) {
        disconnect();
        _setError('Device disconnected');
      }
    });

    final services = await bleDevice.discoverServices();
    fbp.BluetoothCharacteristic? rx;
    fbp.BluetoothCharacteristic? tx;

    for (final svc in services) {
      if (svc.uuid.toString().toUpperCase() == _kServiceUuid) {
        for (final c in svc.characteristics) {
          if (c.uuid.toString().toUpperCase() == _kRxUuid) rx = c;
          if (c.uuid.toString().toUpperCase() == _kTxUuid) tx = c;
        }
      }
    }

    if (rx == null || tx == null) {
      for (final svc in services) {
        for (final c in svc.characteristics) {
          if (rx == null && c.properties.writeWithoutResponse) rx = c;
          if (tx == null && c.properties.notify) tx = c;
        }
      }
    }

    if (rx == null || tx == null) throw Exception('No chat service found');

    await tx.setNotifyValue(true);
    _bleNotifySubscription = tx.onValueReceived.listen(_onRawData);

    _bleDevice = bleDevice;
    _bleRx = rx;
    // Characteristic TX is handled by subscription, so local variable tx isn't assigned to field.
    _onConnectedSuccess(device);
  }

  void _onConnectedSuccess(BTDevice device) {
    _connectedDeviceName = device.name;
    _connectedDeviceAddress = device.address;
    _setState(BtConnectionState.connected);
  }

  Future<void> disconnect() async {
    await _bleNotifySubscription?.cancel();
    await _bleConnectionStateSubscription?.cancel();
    _bleNotifySubscription = null;
    _bleConnectionStateSubscription = null;

    if (_classic != null) {
      await _classic!.disconnect();
    }
    if (_bleDevice != null) {
      await _bleDevice!.disconnect();
    }

    _bleDevice = null;
    _bleRx = null;
    _byteBuffer.clear();
    _connectedDeviceName = null;
    _connectedDeviceAddress = null;

    if (_state != BtConnectionState.disconnected) {
      _setState(BtConnectionState.disconnected);
    }
  }

  // ═════════════════════════════════════════════════════════════════════════
  // COMMUNICATION
  // ═════════════════════════════════════════════════════════════════════════

  Future<void> sendMessage(String text) async {
    if (!isConnected || text.trim().isEmpty) return;

    final trimmed = text.trim();
    final encrypted = _encryption.encrypt(trimmed);
    final packet = '${jsonEncode({'t': encrypted, 'v': '2'})}\n';
    final bytes = Uint8List.fromList(utf8.encode(packet));

    try {
      if (AppPlatform.supportsClassicBluetooth && _classic!.isConnected) {
        await _classic!.send(bytes);
      } else if (_bleRx != null) {
        int maxMtu = (_bleDevice?.mtuNow ?? 23) - 3;
        if (maxMtu < 20) maxMtu = 20;

        for (var i = 0; i < bytes.length; i += maxMtu) {
          final end = (i + maxMtu < bytes.length) ? i + maxMtu : bytes.length;
          await _bleRx!.write(bytes.sublist(i, end),
              withoutResponse: _bleRx!.properties.writeWithoutResponse);
        }
      }

      _messages.add(Message(
        id: _uuid.v4(),
        text: trimmed,
        encryptedText: encrypted,
        isMine: true,
        timestamp: DateTime.now(),
      ));
      _notify();
    } catch (e) {
      _setError('Send failed: $e');
    }
  }

  void _onRawData(List<int> data) {
    _byteBuffer.addAll(data);
    if (_byteBuffer.length > 65536) {
      _byteBuffer.clear();
      return;
    }

    while (true) {
      final idx = _byteBuffer.indexOf(10); // '\n'
      if (idx == -1) break;

      final packetBytes = _byteBuffer.sublist(0, idx);
      _byteBuffer.removeRange(0, idx + 1);

      try {
        final line = utf8.decode(packetBytes, allowMalformed: true).trim();
        if (line.isNotEmpty) {
          _parsePacket(line);
        }
      } catch (e) {
        debugPrint('[BT] Packet decode error: $e');
      }
    }
  }

  void _parsePacket(String line) {
    try {
      final json = jsonDecode(line) as Map<String, dynamic>;
      final cipher = json['t'] as String? ?? '';
      final plain = _encryption.decrypt(cipher);

      _messages.add(Message(
        id: _uuid.v4(),
        text: plain,
        encryptedText: cipher,
        isMine: false,
        timestamp: DateTime.now(),
      ));
    } catch (_) {
      _messages.add(Message(
        id: _uuid.v4(),
        text: '[Decryption Error]',
        encryptedText: line,
        isMine: false,
        timestamp: DateTime.now(),
        isDecryptionError: true,
      ));
    }
    _notify();
  }

  // ═════════════════════════════════════════════════════════════════════════
  // HELPERS
  // ═════════════════════════════════════════════════════════════════════════

  void updatePassphrase(String p) {
    _encryption.updatePassphrase(p);
    _notify();
  }

  // ADDED: Re-implementing the missing clearMessages method
  void clearMessages() {
    _messages.clear();
    _notify();
  }

  void clearError() {
    _errorMessage = null;
    if (_state == BtConnectionState.error) {
      _state = BtConnectionState.disconnected;
    }
    _notify();
  }

  void _setState(BtConnectionState s) {
    _state = s;
    _errorMessage = null;
    _notify();
  }

  void _setError(String msg) {
    _errorMessage = msg;
    _state = BtConnectionState.error;
    _notify();
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _discoveryDebounce?.cancel();
    _discoverySubject.close();
    _bleScanSubscription?.cancel();
    _bleNotifySubscription?.cancel();
    _bleConnectionStateSubscription?.cancel();
    _classic?.dispose();
    super.dispose();
  }
}
