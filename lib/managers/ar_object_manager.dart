import 'dart:typed_data';

import 'package:ar_flutter_plugin/models/ar_anchor.dart';
import 'package:ar_flutter_plugin/models/ar_node.dart';
import 'package:ar_flutter_plugin/utils/json_converters.dart';
import 'package:flutter/services.dart';
import 'package:vector_math/vector_math_64.dart';

// Type definitions to enforce a consistent use of the API
typedef NodeTapResultHandler = void Function(List<String> nodes);
typedef NodePanStartHandler = void Function(String node);
typedef NodePanChangeHandler = void Function(String node);
typedef NodePanEndHandler = void Function(String node, Matrix4 transform);
typedef NodeRotationStartHandler = void Function(String node);
typedef NodeRotationChangeHandler = void Function(String node);
typedef NodeRotationEndHandler = void Function(String node, Matrix4 transform);

/// Manages the all node-related actions of an [ARView]
class ARObjectManager {
  /// Platform channel used for communication from and to [ARObjectManager]
  late MethodChannel _channel;

  /// Debugging status flag. If true, all platform calls are printed. Defaults to false.
  final bool debug;

  /// Callback function that is invoked when the platform detects a tap on a node
  NodeTapResultHandler? onNodeTap;
  NodePanStartHandler? onPanStart;
  NodePanChangeHandler? onPanChange;
  NodePanEndHandler? onPanEnd;
  NodeRotationStartHandler? onRotationStart;
  NodeRotationChangeHandler? onRotationChange;
  NodeRotationEndHandler? onRotationEnd;

  ARObjectManager(int id, {this.debug = false}) {
    _channel = MethodChannel('arobjects_$id');
    _channel.setMethodCallHandler(_platformCallHandler);
    if (debug) {
      print("ARObjectManager initialized");
    }
  }

  Future<void> _platformCallHandler(MethodCall call) {
    if (debug) {
      print('_platformCallHandler call ${call.method} ${call.arguments}');
    }
    try {
      switch (call.method) {
        case 'onError':
          print(call.arguments);
          break;
        case 'onNodeTap':
          if (onNodeTap != null) {
            final tappedNodes = call.arguments as List<dynamic>;
            onNodeTap!(tappedNodes
                .map((tappedNode) => tappedNode.toString())
                .toList());
          }
          break;
        case 'onPanStart':
          if (onPanStart != null) {
            final tappedNode = call.arguments as String;
            // Notify callback
            onPanStart!(tappedNode);
          }
          break;
        case 'onPanChange':
          if (onPanChange != null) {
            final tappedNode = call.arguments as String;
            // Notify callback
            onPanChange!(tappedNode);
          }
          break;
        case 'onPanEnd':
          if (onPanEnd != null) {
            final tappedNodeName = call.arguments["name"] as String;
            final transform =
                MatrixConverter().fromJson(call.arguments['transform'] as List);

            // Notify callback
            onPanEnd!(tappedNodeName, transform);
          }
          break;
        case 'onRotationStart':
          if (onRotationStart != null) {
            final tappedNode = call.arguments as String;
            onRotationStart!(tappedNode);
          }
          break;
        case 'onRotationChange':
          if (onRotationChange != null) {
            final tappedNode = call.arguments as String;
            onRotationChange!(tappedNode);
          }
          break;
        case 'onRotationEnd':
          if (onRotationEnd != null) {
            final tappedNodeName = call.arguments["name"] as String;
            final transform =
                MatrixConverter().fromJson(call.arguments['transform'] as List);

            // Notify callback
            onRotationEnd!(tappedNodeName, transform);
          }
          break;
        default:
          if (debug) {
            print('Unimplemented method ${call.method} ');
          }
      }
    } catch (e) {
      print('Error caught: ' + e.toString());
    }
    return Future.value();
  }

  /// Sets up the AR Object Manager
  onInitialize() {
    _channel.invokeMethod<void>('init', {});
  }

  /// Add given node to the given anchor of the underlying AR scene (or to its top-level if no anchor is given) and listen to any changes made to its transformation
  Future<bool?> addNode(ARNode node, {ARPlaneAnchor? planeAnchor}) async {
    try {
      node.transformNotifier.addListener(() {
        _channel.invokeMethod<void>('transformationChanged', {
          'name': node.name,
          'transformation':
              MatrixValueNotifierConverter().toJson(node.transformNotifier)
        });
      });
      if (planeAnchor != null) {
        planeAnchor.childNodes.add(node.name);
        return await _channel.invokeMethod<bool>('addNodeToPlaneAnchor',
            {'node': node.toMap(), 'anchor': planeAnchor.toJson()});
      } else {
        return await _channel.invokeMethod<bool>('addNode', node.toMap());
      }
    } on PlatformException catch (e) {
      return false;
    }
  }

  /// Place [node] using a stable, drift-corrected raycast against
  /// detected planes / feature points at the given screen point
  /// (defaults to view center).
  ///
  /// On iOS this routes to `ARTrackedRaycast`, on Android to
  /// `Frame.hitTest` + `Anchor.createAnchor`. Both mechanisms are
  /// continuously refined by the AR framework as world tracking
  /// evolves — that's the canonical way to make a virtual object
  /// stay locked to a real-world spot when the user walks around it,
  /// squats, or looks from above. Plain [addNode] (which attaches
  /// to scene root in fixed world coordinates at placement time)
  /// drifts visibly with the camera as the world frame is refined.
  ///
  /// Currently supports `NodeType.localGLTF2` only on both
  /// platforms; other types should keep using [addNode]. Returns
  /// `true` on success, `false` if no surface could be hit within
  /// the platform's retry budget.
  Future<bool?> addNodeRaycast(ARNode node, {Offset? screenPoint}) async {
    try {
      node.transformNotifier.addListener(() {
        _channel.invokeMethod<void>('transformationChanged', {
          'name': node.name,
          'transformation':
              MatrixValueNotifierConverter().toJson(node.transformNotifier),
        });
      });
      final Map<String, dynamic> args = <String, dynamic>{
        'node': node.toMap(),
      };
      if (screenPoint != null) {
        args['screenPoint'] = <String, double>{
          'x': screenPoint.dx,
          'y': screenPoint.dy,
        };
      }
      return await _channel.invokeMethod<bool>('addNodeRaycast', args);
    } on PlatformException catch (e) {
      print('addNodeRaycast: ' + e.toString());
      return false;
    }
  }

  /// Hybrid placement: places [node] **immediately** at a camera-
  /// relative seed position (no plane-detection wait), then in the
  /// background runs raycast and migrates the node onto the first
  /// detected real-world surface point — at which point continuous
  /// drift correction kicks in (same as [addNodeRaycast]).
  ///
  /// Returns `true` as soon as the seed placement is done. The
  /// surface migration happens asynchronously in native code and
  /// produces no further Dart-side callback (the visible effect is
  /// the node sliding onto the surface within ~0-3s).
  ///
  /// Best UX for "user-pointed AR" — instant visibility plus
  /// drift-stable final placement. Currently `NodeType.localGLTF2`
  /// only.
  Future<bool?> addNodeHybrid(ARNode node, {Offset? screenPoint}) async {
    try {
      node.transformNotifier.addListener(() {
        _channel.invokeMethod<void>('transformationChanged', {
          'name': node.name,
          'transformation':
              MatrixValueNotifierConverter().toJson(node.transformNotifier),
        });
      });
      final Map<String, dynamic> args = <String, dynamic>{
        'node': node.toMap(),
      };
      if (screenPoint != null) {
        args['screenPoint'] = <String, double>{
          'x': screenPoint.dx,
          'y': screenPoint.dy,
        };
      }
      return await _channel.invokeMethod<bool>('addNodeHybrid', args);
    } on PlatformException catch (e) {
      print('addNodeHybrid: ' + e.toString());
      return false;
    }
  }

  /// Place [node] at a real-world geographic coordinate
  /// (`latitude`, `longitude`, optional `altitude`). Requires the
  /// session to have been initialized with `enableGeoTracking: true`
  /// (which switches iOS to `ARGeoTrackingConfiguration`).
  ///
  /// On iOS this routes to `ARGeoAnchor`, which is auto-refined by
  /// ARKit as localization improves (Apple VPS in supported regions
  /// — currently major US cities + select international metros;
  /// GPS+heading fallback elsewhere with ~1-3m accuracy).
  ///
  /// On Android, ARCore Geospatial API support is **not yet wired**
  /// in this plugin — requires per-app Google Cloud API key + service
  /// setup. Returns `false` on Android until that integration lands.
  Future<bool?> addNodeGeoAnchor(
    ARNode node, {
    required double latitude,
    required double longitude,
    double? altitude,
  }) async {
    try {
      node.transformNotifier.addListener(() {
        _channel.invokeMethod<void>('transformationChanged', {
          'name': node.name,
          'transformation':
              MatrixValueNotifierConverter().toJson(node.transformNotifier),
        });
      });
      final Map<String, dynamic> args = <String, dynamic>{
        'node': node.toMap(),
        'latitude': latitude,
        'longitude': longitude,
      };
      if (altitude != null) args['altitude'] = altitude;
      return await _channel.invokeMethod<bool>('addNodeGeoAnchor', args);
    } on PlatformException catch (e) {
      print('addNodeGeoAnchor: ' + e.toString());
      return false;
    }
  }

  /// Remove given node from the AR Scene
  removeNode(ARNode node) {
    _channel.invokeMethod<String>('removeNode', {'name': node.name});
  }
}
