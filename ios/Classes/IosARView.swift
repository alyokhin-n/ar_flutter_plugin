import Flutter
import UIKit
import Foundation
import ARKit
import CoreLocation
import Combine
import ARCoreCloudAnchors

class IosARView: NSObject, FlutterPlatformView, ARSCNViewDelegate, UIGestureRecognizerDelegate, ARSessionDelegate {
    let sceneView: ARSCNView
    let coachingView: ARCoachingOverlayView
    let sessionManagerChannel: FlutterMethodChannel
    let objectManagerChannel: FlutterMethodChannel
    let anchorManagerChannel: FlutterMethodChannel
    var showPlanes = false
    var customPlaneTexturePath: String? = nil
    private var trackedPlanes = [UUID: (SCNNode, SCNNode)]()
    let modelBuilder = ArModelBuilder()
    
    var cancellableCollection = Set<AnyCancellable>() //Used to store all cancellables in (needed for working with Futures)
    var anchorCollection = [String: ARAnchor]() //Used to bookkeep all anchors created by Flutter calls
    /// Tracked raycasts per node name. ARTrackedRaycast asks ARKit to
    /// re-run the raycast every frame and call back with refined
    /// world-space results — the canonical mechanism for stable
    /// placement that follows real-world surfaces as ARKit's world
    /// understanding evolves. Stop them via `stopTracking()` on node
    /// removal to free their per-frame budget.
    private var trackedRaycasts = [String: ARTrackedRaycast]()
    
    private var cloudAnchorHandler: CloudAnchorHandler? = nil
    private var arcoreSession: GARSession? = nil
    private var arcoreMode: Bool = false
    private var configuration: ARWorldTrackingConfiguration!
    /// When non-nil, the session is running an `ARGeoTrackingConfiguration`
    /// instead of (mutually-exclusive) `ARWorldTrackingConfiguration`. Geo
    /// mode unlocks `ARGeoAnchor` (place virtual content at lat/lng/alt
    /// that match real-world GPS). Requires iOS 14+, location permission,
    /// device support, and (optionally) Apple's VPS coverage for sub-meter
    /// accuracy. In Ukraine and most regions VPS is unavailable; ARKit
    /// falls back to GPS+heading with ~1-3m accuracy.
    private var geoConfiguration: Any? = nil  // ARGeoTrackingConfiguration when iOS 14+
    private var tappedPlaneAnchorAlignment = ARPlaneAnchor.Alignment.horizontal // default alignment
    
    private var panStartLocation: CGPoint?
    private var panCurrentLocation: CGPoint?
    private var panCurrentVelocity: CGPoint?
    private var panCurrentTranslation: CGPoint?
    private var rotationStartLocation: CGPoint?
    private var rotation: CGFloat?
    private var rotationVelocity: CGFloat?
    private var panningNode: SCNNode?
    private var panningNodeCurrentWorldLocation: SCNVector3?

    init(
        frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?,
        binaryMessenger messenger: FlutterBinaryMessenger
    ) {
        self.sceneView = ARSCNView(frame: frame)
        self.coachingView = ARCoachingOverlayView(frame: frame)
        
        self.sessionManagerChannel = FlutterMethodChannel(name: "arsession_\(viewId)", binaryMessenger: messenger)
        self.objectManagerChannel = FlutterMethodChannel(name: "arobjects_\(viewId)", binaryMessenger: messenger)
        self.anchorManagerChannel = FlutterMethodChannel(name: "aranchors_\(viewId)", binaryMessenger: messenger)
        super.init()

        let configuration = ARWorldTrackingConfiguration() // Create default configuration before initializeARView is called
        self.sceneView.delegate = self
        self.coachingView.delegate = self
        self.sceneView.session.run(configuration)
        // NOTE: `sceneView.session.delegate = self` is set conditionally in
        // `initializeARView` only when `arcoreMode` is enabled (the only
        // place `session(_:didUpdate frame:)` does meaningful work). For
        // non-ARCore mode keeping the delegate unset prevents ARKit from
        // queuing frames against our main-thread callback — which the
        // runtime warns about with "delegate retaining N ARFrames" and
        // which contributes to tracking instability.

        self.sessionManagerChannel.setMethodCallHandler(self.onSessionMethodCalled)
        self.objectManagerChannel.setMethodCallHandler(self.onObjectMethodCalled)
        self.anchorManagerChannel.setMethodCallHandler(self.onAnchorMethodCalled)
    }

    func view() -> UIView {
        return self.sceneView
    }

    func onDispose(_ result:FlutterResult) {
                sceneView.session.pause()
                self.sessionManagerChannel.setMethodCallHandler(nil)
                self.objectManagerChannel.setMethodCallHandler(nil)
                self.anchorManagerChannel.setMethodCallHandler(nil)
                result(nil)
            }

    func onSessionMethodCalled(_ call :FlutterMethodCall, _ result:FlutterResult) {
        let arguments = call.arguments as? Dictionary<String, Any>

        switch call.method {
            case "init":
                //self.sessionManagerChannel.invokeMethod("onError", arguments: ["SessionTEST from iOS"])
                //result(nil)
                initializeARView(arguments: arguments!, result: result)
                break
            case "getCameraPose":
                if let cameraPose = sceneView.session.currentFrame?.camera.transform {
                    result(serializeMatrix(cameraPose))
                } else {
                    result(FlutterError())
                }
                break
            case "getAnchorPose":
            if let cameraPose = anchorCollection[arguments?["anchorId"] as! String]?.transform {
                    result(serializeMatrix(cameraPose))
                } else {
                    result(FlutterError())
                }
                break
            case "snapshot":
                // call the SCNView Snapshot method and return the Image
                let snapshotImage = sceneView.snapshot()
                if let bytes = snapshotImage.pngData() {
                    let data = FlutterStandardTypedData(bytes:bytes)
                    result(data)
                } else {
                    result(nil)
                }
            case "dispose":
                onDispose(result)
                result(nil)
                break
            default:
                result(FlutterMethodNotImplemented)
                break
        }
    }

    func onObjectMethodCalled(_ call :FlutterMethodCall, _ result: @escaping FlutterResult) {
        let arguments = call.arguments as? Dictionary<String, Any>
          
        switch call.method {
            case "init":
                self.objectManagerChannel.invokeMethod("onError", arguments: ["ObjectTEST from iOS"])
                result(nil)
                break
            case "addNode":
                addNode(dict_node: arguments!).sink(receiveCompletion: {completion in }, receiveValue: { val in
                       result(val)
                    }).store(in: &self.cancellableCollection)
                break
            case "addNodeToPlaneAnchor":
                if let dict_node = arguments!["node"] as? Dictionary<String, Any>, let dict_anchor = arguments!["anchor"] as? Dictionary<String, Any> {
                    addNode(dict_node: dict_node, dict_anchor: dict_anchor).sink(receiveCompletion: {completion in }, receiveValue: { val in
                           result(val)
                        }).store(in: &self.cancellableCollection)
                }
                break
            case "addNodeRaycast":
                let dict_node = (arguments!["node"] as? Dictionary<String, Any>) ?? arguments!
                var screenPoint: CGPoint = self.sceneViewCenter()
                if let sp = arguments!["screenPoint"] as? Dictionary<String, Any>,
                   let x = sp["x"] as? Double,
                   let y = sp["y"] as? Double {
                    screenPoint = CGPoint(x: x, y: y)
                }
                placeNodeViaTrackedRaycast(
                    dict_node: dict_node,
                    screenPoint: screenPoint,
                    retriesLeft: 12,
                    result: result
                )
                break
            case "addNodeHybrid":
                let dict_node = (arguments!["node"] as? Dictionary<String, Any>) ?? arguments!
                var screenPoint: CGPoint = self.sceneViewCenter()
                if let sp = arguments!["screenPoint"] as? Dictionary<String, Any>,
                   let x = sp["x"] as? Double,
                   let y = sp["y"] as? Double {
                    screenPoint = CGPoint(x: x, y: y)
                }
                placeNodeHybrid(
                    dict_node: dict_node,
                    screenPoint: screenPoint,
                    result: result
                )
                break
            case "addNodeGeoAnchor":
                if #available(iOS 14.0, *) {
                    placeNodeViaGeoAnchor(arguments: arguments!, result: result)
                } else {
                    sessionManagerChannel.invokeMethod(
                        "onError",
                        arguments: ["addNodeGeoAnchor requires iOS 14+"]
                    )
                    result(false)
                }
                break
            case "removeNode":
                if let name = arguments!["name"] as? String {
                    if let tracked = trackedRaycasts.removeValue(forKey: name) {
                        tracked.stopTracking()
                    }
                    sceneView.scene.rootNode.childNode(withName: name, recursively: true)?.removeFromParentNode()
                }
                break
            case "transformationChanged":
                if let name = arguments!["name"] as? String, let transform = arguments!["transformation"] as? Array<NSNumber> {
                    transformNode(name: name, transform: transform)
                    result(nil)
                }
                break
            default:
                result(FlutterMethodNotImplemented)
                break
        }
    }

    func onAnchorMethodCalled(_ call :FlutterMethodCall, _ result: @escaping FlutterResult) {
        let arguments = call.arguments as? Dictionary<String, Any>
          
        switch call.method {
            case "init":
                self.objectManagerChannel.invokeMethod("onError", arguments: ["ObjectTEST from iOS"])
                result(nil)
                break
            case "addAnchor":
                if let type = arguments!["type"] as? Int {
                    switch type {
                    case 0: //Plane Anchor
                        if let transform = arguments!["transformation"] as? Array<NSNumber>, let name = arguments!["name"] as? String {
                            addPlaneAnchor(transform: transform, name: name)
                            result(true)
                        }
                        result(false)
                        break
                    default:
                        result(false)
                    
                    }
                }
                result(nil)
                break
            case "removeAnchor":
                if let name = arguments!["name"] as? String {
                    deleteAnchor(anchorName: name)
                }
                break
            case "initGoogleCloudAnchorMode":
                arcoreSession = try! GARSession.session()

                if (arcoreSession != nil){
                    let configuration = GARSessionConfiguration();
                    configuration.cloudAnchorMode = .enabled;
                    arcoreSession?.setConfiguration(configuration, error: nil);
                    if let token = JWTGenerator().generateWebToken(){
                        arcoreSession!.setAuthToken(token)
                        
                        cloudAnchorHandler = CloudAnchorHandler(session: arcoreSession!)
                        arcoreSession!.delegate = cloudAnchorHandler
                        arcoreSession!.delegateQueue = DispatchQueue.main
                        
                        arcoreMode = true
                    } else {
                        sessionManagerChannel.invokeMethod("onError", arguments: ["Error generating JWT, have you added cloudAnchorKey.json into the example/ios/Runner directory?"])
                    }
                } else {
                    sessionManagerChannel.invokeMethod("onError", arguments: ["Error initializing Google AR Session"])
                }
                    
                break
            case "uploadAnchor":
                if let anchorName = arguments!["name"] as? String, let anchor = anchorCollection[anchorName] {
                    print("---------------- HOSTING INITIATED ------------------")
                    if let ttl = arguments!["ttl"] as? Int {
                        cloudAnchorHandler?.hostCloudAnchorWithTtl(anchorName: anchorName, anchor: anchor, listener: cloudAnchorUploadedListener(parent: self), ttl: ttl)
                    } else {
                        cloudAnchorHandler?.hostCloudAnchor(anchorName: anchorName, anchor: anchor, listener: cloudAnchorUploadedListener(parent: self))
                    }
                }
                result(true)
                break
            case "downloadAnchor":
                if let anchorId = arguments!["cloudanchorid"] as? String {
                    print("---------------- RESOLVING INITIATED ------------------")
                    cloudAnchorHandler?.resolveCloudAnchor(anchorId: anchorId, listener: cloudAnchorDownloadedListener(parent: self))
                }
                break
            default:
                result(FlutterMethodNotImplemented)
                break
        }
    }

    func initializeARView(arguments: Dictionary<String,Any>, result: FlutterResult){
        // Geo-tracking opt-in. When enabled and supported, swap world
        // tracking for ARGeoTrackingConfiguration which enables
        // ARGeoAnchor (lat/lng/alt-based placement). Apps must choose
        // upfront — geo and world tracking are mutually exclusive.
        if #available(iOS 14.0, *),
           let enableGeo = arguments["enableGeoTracking"] as? Bool,
           enableGeo,
           ARGeoTrackingConfiguration.isSupported {
            let geoConfig = ARGeoTrackingConfiguration()
            geoConfig.planeDetection = [.horizontal, .vertical]
            self.geoConfiguration = geoConfig
            self.sceneView.session.run(geoConfig)
            // Skip the rest of world-tracking-specific setup; geo
            // mode does not use environmentTexturing, scene
            // reconstruction, or worldAlignment in the same way.
            self.sessionManagerChannel.invokeMethod(
                "onError",
                arguments: ["GeoTracking enabled — using ARGeoTrackingConfiguration. raycast / world-tracking features disabled in this mode."]
            )
            return
        }
        // Set plane detection configuration
        self.configuration = ARWorldTrackingConfiguration()
        // Environment texturing is OFF by default — `.automatic` forces ARKit
        // to continuously generate HDR cube-maps from the camera feed, which
        // costs measurable CPU/GPU on older devices (iPhone 11 / A13) and
        // does not contribute to placement quality for matte models.
        if let envTex = arguments["environmentTexturing"] as? Bool, envTex {
            self.configuration.environmentTexturing = .automatic
        } else {
            self.configuration.environmentTexturing = .none
        }
        // World alignment: `.gravity` (default, indoor-friendly) or
        // `.gravityAndHeading` (uses magnetometer to fix yaw against true
        // north — better outdoor stability when compass is reliable).
        if let align = arguments["worldAlignment"] as? String,
           align == "gravityAndHeading" {
            self.configuration.worldAlignment = .gravityAndHeading
        }
        // LiDAR scene reconstruction (iPhone 12 Pro+, iPad Pro). When
        // enabled and supported, ARKit builds a real-time triangle mesh
        // of the surroundings and exposes per-frame scene depth. This
        // is the foundation for occluding virtual content by real
        // furniture / walls. Older devices ignore the flag silently.
        if #available(iOS 13.4, *),
           let enableSR = arguments["enableSceneReconstruction"] as? Bool,
           enableSR,
           ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            self.configuration.sceneReconstruction = .mesh
            // Smooth scene depth (LiDAR-only) gives the depth texture
            // used by per-fragment occlusion shaders downstream.
            if #available(iOS 14.0, *),
               ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
                self.configuration.frameSemantics.insert(.smoothedSceneDepth)
            }
        }
        if let planeDetectionConfig = arguments["planeDetectionConfig"] as? Int {
            switch planeDetectionConfig {
                case 1: 
                    configuration.planeDetection = .horizontal
                
                case 2: 
                    if #available(iOS 11.3, *) {
                        configuration.planeDetection = .vertical
                    }
                case 3: 
                    if #available(iOS 11.3, *) {
                        configuration.planeDetection = [.horizontal, .vertical]
                    }
                default: 
                    configuration.planeDetection = []
            }
        }

        // Set plane rendering options
        if let configShowPlanes = arguments["showPlanes"] as? Bool {
            showPlanes = configShowPlanes
            if (showPlanes){
                // Visualize currently tracked planes
                for plane in trackedPlanes.values {
                    plane.0.addChildNode(plane.1)
                }
            } else {
                // Remove currently visualized planes
                for plane in trackedPlanes.values {
                    plane.1.removeFromParentNode()
                }
            }
        }
        if let configCustomPlaneTexturePath = arguments["customPlaneTexturePath"] as? String {
            customPlaneTexturePath = configCustomPlaneTexturePath
        }

        // Set debug options
        var debugOptions = ARSCNDebugOptions().rawValue
        if let showFeaturePoints = arguments["showFeaturePoints"] as? Bool {
            if (showFeaturePoints) {
                debugOptions |= ARSCNDebugOptions.showFeaturePoints.rawValue
            }
        }
        if let showWorldOrigin = arguments["showWorldOrigin"] as? Bool {
            if (showWorldOrigin) {
                debugOptions |= ARSCNDebugOptions.showWorldOrigin.rawValue
            }
        }
        self.sceneView.debugOptions = ARSCNDebugOptions(rawValue: debugOptions)
        
        if let configHandleTaps = arguments["handleTaps"] as? Bool {
            if (configHandleTaps){
                let tapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
                tapGestureRecognizer.delegate = self
                self.sceneView.gestureRecognizers?.append(tapGestureRecognizer)
            }
        }

        if let configHandlePans = arguments["handlePans"] as? Bool {
            if (configHandlePans){
                let panGestureRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
                panGestureRecognizer.maximumNumberOfTouches = 1
                panGestureRecognizer.delegate = self
                self.sceneView.gestureRecognizers?.append(panGestureRecognizer)
            }
        }
        
        if let configHandleRotation = arguments["handleRotation"] as? Bool {
            if (configHandleRotation){
                let rotationGestureRecognizer = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))
                rotationGestureRecognizer.delegate = self
                self.sceneView.gestureRecognizers?.append(rotationGestureRecognizer)
            }
        }
        
        // Add coaching view
        if let configShowAnimatedGuide = arguments["showAnimatedGuide"] as? Bool {
            if configShowAnimatedGuide {
                if self.sceneView.superview != nil && self.coachingView.superview == nil {
                    self.sceneView.addSubview(self.coachingView)
        //            self.coachingView.translatesAutoresizingMaskIntoConstraints = false
                    self.coachingView.autoresizingMask = [
                          .flexibleWidth, .flexibleHeight
                        ]
                    self.coachingView.session = self.sceneView.session
                    self.coachingView.activatesAutomatically = true
                    if configuration.planeDetection == .horizontal {
                        self.coachingView.goal = .horizontalPlane
                    }else{
                        self.coachingView.goal = .verticalPlane
                    }
                    // TODO: look into constraints issue. This causes a crash:
                    /**
                     Terminating app due to uncaught exception 'NSGenericException', reason: 'Unable to activate constraint with anchors <NSLayoutXAxisAnchor:0x28342dec0 "ARCoachingOverlayView:0x13a470ae0.centerX"> and <NSLayoutXAxisAnchor:0x28342c680 "FlutterTouchInterceptingView:0x10bad1c90.centerX"> because they have no common ancestor.  Does the constraint or its anchors reference items in different view hierarchies?  That's illegal.'
                     */
        //            NSLayoutConstraint.activate([
        //                self.coachingView.centerXAnchor.constraint(equalTo: self.sceneView.superview!.centerXAnchor),
        //                self.coachingView.centerYAnchor.constraint(equalTo: self.sceneView.superview!.centerYAnchor),
        //                self.coachingView.widthAnchor.constraint(equalTo: self.sceneView.superview!.widthAnchor),
        //                self.coachingView.heightAnchor.constraint(equalTo: self.sceneView.superview!.heightAnchor)
        //                ])
                }
            }
        }
    
        // Update session configuration
        self.sceneView.session.run(configuration)
    }

    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        
        if let planeAnchor = anchor as? ARPlaneAnchor{
            let plane = modelBuilder.makePlane(anchor: planeAnchor, flutterAssetFile: customPlaneTexturePath)
            trackedPlanes[anchor.identifier] = (node, plane)
            if (showPlanes) {
                node.addChildNode(plane)
            }
        }
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        
        if let planeAnchor = anchor as? ARPlaneAnchor, let plane = trackedPlanes[anchor.identifier] {
            modelBuilder.updatePlaneNode(planeNode: plane.1, anchor: planeAnchor)
        }
    }

    func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
        trackedPlanes.removeValue(forKey: anchor.identifier)
    }
    
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        if (arcoreMode) {
            do {
                try arcoreSession!.update(frame)
            } catch {
                print(error)
            }
        }
    }

    func addNode(dict_node: Dictionary<String, Any>, dict_anchor: Dictionary<String, Any>? = nil) -> Future<Bool, Never> {

        return Future {promise in
            
            switch (dict_node["type"] as! Int) {
                case 0: // GLTF2 Model from Flutter asset folder
                    // Get path to given Flutter asset
                    let key = FlutterDartProject.lookupKey(forAsset: dict_node["uri"] as! String)
                    // Add object to scene
                    if let node: SCNNode = self.modelBuilder.makeNodeFromGltf(name: dict_node["name"] as! String, modelPath: key, transformation: dict_node["transformation"] as? Array<NSNumber>) {
                        if let anchorName = dict_anchor?["name"] as? String, let anchorType = dict_anchor?["type"] as? Int {
                            switch anchorType{
                                case 0: //PlaneAnchor
                                    if let anchor = self.anchorCollection[anchorName]{
                                        // Attach node to the top-level node of the specified anchor
                                        self.sceneView.node(for: anchor)?.addChildNode(node)
                                        promise(.success(true))
                                    } else {
                                        promise(.success(false))
                                    }
                                default:
                                    promise(.success(false))
                                }
                            
                        } else {
                            // Attach to top-level node of the scene
                            self.sceneView.scene.rootNode.addChildNode(node)
                            promise(.success(true))
                        }
                        promise(.success(false))
                    } else {
                        self.sessionManagerChannel.invokeMethod("onError", arguments: ["Unable to load renderable \(dict_node["uri"] as! String)"])
                        promise(.success(false))
                    }
                    break
                case 1: // GLB Model from the web
                    // Add object to scene
                    self.modelBuilder.makeNodeFromWebGlb(name: dict_node["name"] as! String, modelURL: dict_node["uri"] as! String, transformation: dict_node["transformation"] as? Array<NSNumber>)
                    .sink(receiveCompletion: {
                                    completion in print("Async Model Downloading Task completed: ", completion)
                    }, receiveValue: { val in
                        if let node: SCNNode = val {
                            if let anchorName = dict_anchor?["name"] as? String, let anchorType = dict_anchor?["type"] as? Int {
                                switch anchorType{
                                    case 0: //PlaneAnchor
                                        if let anchor = self.anchorCollection[anchorName]{
                                            // Attach node to the top-level node of the specified anchor
                                            self.sceneView.node(for: anchor)?.addChildNode(node)
                                            promise(.success(true))
                                        } else {
                                            promise(.success(false))
                                        }
                                    default:
                                        promise(.success(false))
                                    }
                                
                            } else {
                                // Attach to top-level node of the scene
                                self.sceneView.scene.rootNode.addChildNode(node)
                                promise(.success(true))
                            }
                            promise(.success(false))
                        } else {
                            self.sessionManagerChannel.invokeMethod("onError", arguments: ["Unable to load renderable \(dict_node["name"] as! String)"])
                            promise(.success(false))
                        }
                    }).store(in: &self.cancellableCollection)
                    break
                case 2: // GLB Model from the app's documents folder
                    // Get path to given file system asset
                    let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
                    let documentsDirectory = paths[0]
                    let targetPath = documentsDirectory.appendingPathComponent(dict_node["uri"] as! String).path
 
                    // Add object to scene
                    if let node: SCNNode = self.modelBuilder.makeNodeFromFileSystemGLB(name: dict_node["name"] as! String, modelPath: targetPath, transformation: dict_node["transformation"] as? Array<NSNumber>) {
                        if let anchorName = dict_anchor?["name"] as? String, let anchorType = dict_anchor?["type"] as? Int {
                            switch anchorType{
                                case 0: //PlaneAnchor
                                    if let anchor = self.anchorCollection[anchorName]{
                                        // Attach node to the top-level node of the specified anchor
                                        self.sceneView.node(for: anchor)?.addChildNode(node)
                                        promise(.success(true))
                                    } else {
                                        promise(.success(false))
                                    }
                                default:
                                    promise(.success(false))
                                }
                            
                        } else {
                            // Attach to top-level node of the scene
                            self.sceneView.scene.rootNode.addChildNode(node)
                            promise(.success(true))
                        }
                        promise(.success(false))
                    } else {
                        self.sessionManagerChannel.invokeMethod("onError", arguments: ["Unable to load renderable \(dict_node["uri"] as! String)"])
                        promise(.success(false))
                    }
                    break
                case 3: //fileSystemAppFolderGLTF2
                    // Get path to given file system asset
                    let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
                    let documentsDirectory = paths[0]
                    let targetPath = documentsDirectory.appendingPathComponent(dict_node["uri"] as! String).path

                    // Add object to scene
                    if let node: SCNNode = self.modelBuilder.makeNodeFromFileSystemGltf(name: dict_node["name"] as! String, modelPath: targetPath, transformation: dict_node["transformation"] as? Array<NSNumber>) {
                        if let anchorName = dict_anchor?["name"] as? String, let anchorType = dict_anchor?["type"] as? Int {
                            switch anchorType{
                                case 0: //PlaneAnchor
                                    if let anchor = self.anchorCollection[anchorName]{
                                        // Attach node to the top-level node of the specified anchor
                                        self.sceneView.node(for: anchor)?.addChildNode(node)
                                        promise(.success(true))
                                    } else {
                                        promise(.success(false))
                                    }
                                default:
                                    promise(.success(false))
                                }
                            
                        } else {
                            // Attach to top-level node of the scene
                            self.sceneView.scene.rootNode.addChildNode(node)
                            promise(.success(true))
                        }
                        promise(.success(false))
                    } else {
                        self.sessionManagerChannel.invokeMethod("onError", arguments: ["Unable to load renderable \(dict_node["uri"] as! String)"])
                        promise(.success(false))
                    }
                    break
                default:
                    promise(.success(false))
            }
            
        }
    }
    
    func transformNode(name: String, transform: Array<NSNumber>) {
        let node = sceneView.scene.rootNode.childNode(withName: name, recursively: true)
        node?.transform = deserializeMatrix4(transform)
    }
    
    @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard let sceneView = recognizer.view as? ARSCNView else {
            return
        }
        let touchLocation = recognizer.location(in: sceneView)
    
        let allHitResults = sceneView.hitTest(touchLocation, options: [SCNHitTestOption.searchMode : SCNHitTestSearchMode.closest.rawValue])
        // Because 3D model loading can lead to composed nodes, we have to traverse through a node's parent until the parent node with the name assigned by the Flutter API is found
        let nodeHitResults: Array<String> = allHitResults.compactMap { nearestParentWithNameStart(node: $0.node, characters: "[#")?.name }
        if (nodeHitResults.count != 0) {
            self.objectManagerChannel.invokeMethod("onNodeTap", arguments: Array(Set(nodeHitResults))) // Chaining of Array and Set is used to remove duplicates
            return
        }
            
        let planeTypes: ARHitTestResult.ResultType
        if #available(iOS 11.3, *){
            planeTypes = ARHitTestResult.ResultType([.existingPlaneUsingGeometry, .featurePoint])
        }else {
            planeTypes = ARHitTestResult.ResultType([.existingPlaneUsingExtent, .featurePoint])
        }
        
        let planeAndPointHitResults = sceneView.hitTest(touchLocation, types: planeTypes)
        
        // store the alignment of the tapped plane anchor so we can refer to is later when transforming the node
        if planeAndPointHitResults.count > 0, let hitAnchor = planeAndPointHitResults.first?.anchor as? ARPlaneAnchor {
            self.tappedPlaneAnchorAlignment = hitAnchor.alignment
        }
            
        let serializedPlaneAndPointHitResults = planeAndPointHitResults.map{serializeHitResult($0)}
        if (serializedPlaneAndPointHitResults.count != 0) {
            self.sessionManagerChannel.invokeMethod("onPlaneOrPointTap", arguments: serializedPlaneAndPointHitResults)
        }
    }

    @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let sceneView = recognizer.view as? ARSCNView else {
            return
        }

        // State Begins
        if recognizer.state == UIGestureRecognizer.State.began
        {
            panStartLocation = recognizer.location(in: sceneView)
            if let startLocation = panStartLocation {
                let allHitResults = sceneView.hitTest(startLocation, options: [SCNHitTestOption.searchMode : SCNHitTestSearchMode.closest.rawValue])
                // Because 3D model loading can lead to composed nodes, we have to traverse through a node's parent until the parent node with the name assigned by the Flutter API is found
                let nodeHitResults: Array<String> = allHitResults.compactMap {
                    if let nearestNode = nearestParentWithNameStart(node: $0.node, characters: "[#") {
                        panningNode = nearestNode
                        return nearestNode.name
                    }else{
                        return nil
                    }
                }
                if (nodeHitResults.count != 0 && panningNode != nil) {
                    panningNodeCurrentWorldLocation = panningNode!.worldPosition
                    self.objectManagerChannel.invokeMethod("onPanStart", arguments: panningNode!.name) // Chaining of Array and Set is used to remove duplicates
                    return
                }
            }
        }
        // State Changes
        if(recognizer.state == UIGestureRecognizer.State.changed)
        {
            // the velocity of the gesture is how fast it is moving. This can be used to translate the position of the node.
            panCurrentVelocity = recognizer.velocity(in: sceneView)
            panCurrentLocation = recognizer.location(in: sceneView)
            panCurrentTranslation = recognizer.translation(in: sceneView)

            if let panLoc = panCurrentLocation, let panNode = panningNode {
                if let query = sceneView.raycastQuery(from: panLoc, allowing: .estimatedPlane, alignment: .any) {
                    guard let result = self.sceneView.session.raycast(query).first else {
                        return
                    }
                    let posX = result.worldTransform.columns.3.x
                    let posY = result.worldTransform.columns.3.y
                    let posZ = result.worldTransform.columns.3.z
                    panNode.worldPosition = SCNVector3(posX, posY, posZ)
                }
                self.objectManagerChannel.invokeMethod("onPanChange", arguments: panNode.name)
            }
        }
        // State Ended
        if(recognizer.state == UIGestureRecognizer.State.ended)
        {
            // kill variables
            panStartLocation = nil
            panCurrentLocation = nil
            self.objectManagerChannel.invokeMethod("onPanEnd", arguments: serializeLocalTransformation(node: panningNode))
            panningNode = nil
        }
    }
    
    @objc func handleRotation(_ recognizer: UIRotationGestureRecognizer) {
        guard let sceneView = recognizer.view as? ARSCNView else {
            return
        }

        // State Begins
        if recognizer.state == UIGestureRecognizer.State.began
        {
            rotationStartLocation = recognizer.location(in: sceneView)
            if let startLocation = rotationStartLocation {
                let allHitResults = sceneView.hitTest(startLocation, options: [SCNHitTestOption.searchMode : SCNHitTestSearchMode.closest.rawValue])
                // Because 3D model loading can lead to composed nodes, we have to traverse through a node's parent until the parent node with the name assigned by the Flutter API is found
                let nodeHitResults: Array<String> = allHitResults.compactMap {
                    if let nearestNode = nearestParentWithNameStart(node: $0.node, characters: "[#") {
                        panningNode = nearestNode
                        return nearestNode.name
                    }else{
                        return nil
                    }
                }
                if (nodeHitResults.count != 0 && panningNode != nil) {
                    self.objectManagerChannel.invokeMethod("onRotationStart", arguments: panningNode!.name) // Chaining of Array and Set is used to remove duplicates
                    return
                }
            }
        }
        // State Changes
        if(recognizer.state == UIGestureRecognizer.State.changed)
        {
            // the velocity of the gesture is how fast it is moving. This can be used to translate the position of the node.
            rotation = recognizer.rotation
            rotationVelocity = recognizer.velocity

            if let r = rotationVelocity, let panNode = panningNode {
                // velocity needs to be reduced substantially otherwise the rotation change seems too fast as radians; also needs inverting to match the movement of the fingers as they rotate on the screen
                let r2 = (r*0.01) * -1
                let nodeRotation = panNode.rotation
                let rotation: SCNQuaternion!
                let planeAlignment = self.tappedPlaneAnchorAlignment
                if planeAlignment == .horizontal {
                    rotation = SCNQuaternion(x: 0, y: 1, z: 0, w: nodeRotation.w+Float(r2)) // quickest way to convert screen into world positions (meters)
                }else{
                    rotation = SCNQuaternion(x: 0, y: 0, z: 1, w: nodeRotation.w+Float(r2)) // quickest way to convert screen into world positions (meters)
                }
                panNode.rotation = rotation
                self.objectManagerChannel.invokeMethod("onRotationChange", arguments: panNode.name)
            }

            // update position of panning node if it has been created
            // panningNode.position + the gesture delta
        }
        // State Ended
        if(recognizer.state == UIGestureRecognizer.State.ended)
        {
            // kill variables
            rotation = nil
            rotationVelocity = nil
            self.objectManagerChannel.invokeMethod("onRotationEnd", arguments: serializeLocalTransformation(node: panningNode))
            panningNode = nil
        }
    
    }

    // Recursive helper function to traverse a node's parents until a node with a name starting with the specified characters is found
    func nearestParentWithNameStart(node: SCNNode?, characters: String) -> SCNNode? {
        if let nodeNamePrefix = node?.name?.prefix(characters.count) {
            if (nodeNamePrefix == characters) { return node }
        }
        if let parent = node?.parent { return nearestParentWithNameStart(node: parent, characters: characters) }
        return nil
    }
    
    func addPlaneAnchor(transform: Array<NSNumber>, name: String){
        let arAnchor = ARAnchor(transform: simd_float4x4(deserializeMatrix4(transform)))
        anchorCollection[name] = arAnchor
        sceneView.session.add(anchor: arAnchor)
        // Ensure root node is added to anchor before any other function can run (if this isn't done, addNode could fail because anchor does not have a root node yet).
        // The root node is added to the anchor as soon as the async rendering loop runs once, more specifically the function "renderer(_:nodeFor:)"
        while (sceneView.node(for: arAnchor) == nil) {
            usleep(1) // wait 1 millionth of a second
        }
    }
    
    func deleteAnchor(anchorName: String) {
        if let anchor = anchorCollection[anchorName]{
            // Delete all child nodes
            if var attachedNodes = sceneView.node(for: anchor)?.childNodes {
                attachedNodes.removeAll()
            }
            // Remove anchor
            sceneView.session.remove(anchor: anchor)
            // Update bookkeeping
            anchorCollection.removeValue(forKey: anchorName)
        }
    }
    
    private class cloudAnchorUploadedListener: CloudAnchorListener {
        private var parent: IosARView
        
        init(parent: IosARView) {
            self.parent = parent
        }
        
        func onCloudTaskComplete(anchorName: String?, anchor: GARAnchor?) {
            if let cloudState = anchor?.cloudState {
                if (cloudState == GARCloudAnchorState.success) {
                    var args = Dictionary<String, String?>()
                    args["name"] = anchorName
                    args["cloudanchorid"] = anchor?.cloudIdentifier
                    parent.anchorManagerChannel.invokeMethod("onCloudAnchorUploaded", arguments: args)
                } else {
                    print("Error uploading anchor, state: \(parent.decodeCloudAnchorState(state: cloudState))")
                    parent.sessionManagerChannel.invokeMethod("onError", arguments: ["Error uploading anchor, state: \(parent.decodeCloudAnchorState(state: cloudState))"])
                    return
                }
            }
        }
    }

    private class cloudAnchorDownloadedListener: CloudAnchorListener {
        private var parent: IosARView
        
        init(parent: IosARView) {
            self.parent = parent
        }
        
        func onCloudTaskComplete(anchorName: String?, anchor: GARAnchor?) {
            if let cloudState = anchor?.cloudState {
                if (cloudState == GARCloudAnchorState.success) {
                    let newAnchor = ARAnchor(transform: anchor!.transform)
                    // Register new anchor on the Flutter side of the plugin
                    parent.anchorManagerChannel.invokeMethod("onAnchorDownloadSuccess", arguments: serializeAnchor(anchor: newAnchor, anchorNode: nil, ganchor: anchor!, name: anchorName), result: { result in
                        if let anchorName = result as? String {
                            self.parent.sceneView.session.add(anchor: newAnchor)
                            self.parent.anchorCollection[anchorName] = newAnchor
                        } else {
                            self.parent.sessionManagerChannel.invokeMethod("onError", arguments: ["Error while registering downloaded anchor at the AR Flutter plugin"])
                        }

                    })
                } else {
                    print("Error downloading anchor, state \(cloudState)")
                    parent.sessionManagerChannel.invokeMethod("onError", arguments: ["Error downloading anchor, state \(cloudState)"])
                    return
                }
            }
        }
    }
    
    func decodeCloudAnchorState(state: GARCloudAnchorState) -> String {
        switch state {
        case .errorCloudIdNotFound:
            return "Cloud anchor id not found"
        case .errorHostingDatasetProcessingFailed:
            return "Dataset processing failed, feature map insufficient"
        case .errorHostingServiceUnavailable:
            return "Hosting service unavailable"
        case .errorInternal:
            return "Internal error"
        case .errorNotAuthorized:
            return "Authentication failed: Not Authorized"
        case .errorResolvingSdkVersionTooNew:
            return "Resolving Sdk version too new"
        case .errorResolvingSdkVersionTooOld:
            return "Resolving Sdk version too old"
        case .errorResourceExhausted:
            return " Resource exhausted"
        case .none:
            return "Empty state"
        case .taskInProgress:
            return "Task in progress"
        case .success:
            return "Success"
        case .errorServiceUnavailable:
            return "Cloud Anchor Service unavailable"
        case .errorResolvingLocalizationNoMatch:
            return "No match"
        @unknown default:
            return "Unknown"
        }
    }
}

// ---------------------- ARCoachingOverlayViewDelegate ---------------------------------------

extension IosARView: ARCoachingOverlayViewDelegate {
    
    func coachingOverlayViewWillActivate(_ coachingOverlayView: ARCoachingOverlayView){
        // use this delegate method to hide anything in the UI that could cover the coaching overlay view
    }
    
    func coachingOverlayViewDidRequestSessionReset(_ coachingOverlayView: ARCoachingOverlayView) {
        // Reset the session.
        self.sceneView.session.run(configuration, options: [.resetTracking])
    }

    // MARK: - Geo-anchor placement (iOS 14+)

    /// Place a node at a real-world geographic coordinate. Requires
    /// the session to be running `ARGeoTrackingConfiguration` (set up
    /// by passing `enableGeoTracking: true` to the init args). The
    /// resulting `ARGeoAnchor` is automatically refined by ARKit as
    /// the localization improves — Apple VPS in supported regions,
    /// GPS+heading fallback elsewhere.
    @available(iOS 14.0, *)
    private func placeNodeViaGeoAnchor(
        arguments: Dictionary<String, Any>,
        result: @escaping FlutterResult
    ) {
        guard self.geoConfiguration != nil else {
            sessionManagerChannel.invokeMethod(
                "onError",
                arguments: ["addNodeGeoAnchor: session is NOT running ARGeoTrackingConfiguration. Pass `enableGeoTracking: true` to onInitialize."]
            )
            result(false)
            return
        }
        guard let dict_node = arguments["node"] as? Dictionary<String, Any>,
              let lat = arguments["latitude"] as? Double,
              let lng = arguments["longitude"] as? Double else {
            result(false)
            return
        }
        let altitudeOpt = arguments["altitude"] as? Double  // nil = ARKit infers ground level

        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        let anchor: ARGeoAnchor
        if let alt = altitudeOpt {
            anchor = ARGeoAnchor(coordinate: coord, altitude: alt)
        } else {
            anchor = ARGeoAnchor(coordinate: coord)
        }
        let anchorName = (dict_node["name"] as? String) ?? UUID().uuidString
        anchorCollection[anchorName] = anchor
        sceneView.session.add(anchor: anchor)

        // Build the node and parent it to the anchor's SCNNode once
        // ARSCNView creates one. The renderer(_:didAdd:for:) callback
        // handles ARGeoAnchor like any other anchor.
        guard let nodeType = dict_node["type"] as? Int, nodeType == 0,
              let uri = dict_node["uri"] as? String else {
            sceneView.session.remove(anchor: anchor)
            anchorCollection.removeValue(forKey: anchorName)
            result(false)
            return
        }
        let key = FlutterDartProject.lookupKey(forAsset: uri)
        guard let node = self.modelBuilder.makeNodeFromGltf(
            name: anchorName,
            modelPath: key,
            transformation: dict_node["transformation"] as? Array<NSNumber>
        ) else {
            sceneView.session.remove(anchor: anchor)
            anchorCollection.removeValue(forKey: anchorName)
            result(false)
            return
        }

        // Wait briefly for the anchor's node to be created, then
        // attach. ARGeoAnchor SCNNodes are created on the next render
        // tick after `session.add`.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            if let anchorNode = self.sceneView.node(for: anchor) {
                anchorNode.addChildNode(node)
                result(true)
            } else {
                // Retry once more
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    guard let self = self else { return }
                    if let anchorNode = self.sceneView.node(for: anchor) {
                        anchorNode.addChildNode(node)
                        result(true)
                    } else {
                        self.sceneView.session.remove(anchor: anchor)
                        self.anchorCollection.removeValue(forKey: anchorName)
                        result(false)
                    }
                }
            }
        }
    }

    // MARK: - Tracked-raycast placement

    private func sceneViewCenter() -> CGPoint {
        return CGPoint(x: sceneView.bounds.midX, y: sceneView.bounds.midY)
    }

    /// Hybrid placement: instant camera-relative seed + background
    /// migration to a tracked raycast result once ARKit finds a real
    /// surface.
    ///
    /// Goal: best-of-both UX. The user sees the prism immediately on
    /// AR view ready (no plane-detection wait) while the longer-term
    /// drift-stable position is found in parallel. When the first
    /// tracked-raycast update lands, the node's `simdWorldPosition`
    /// is updated to the surface point and continuously refined
    /// thereafter — same drift correction as the pure-raycast path.
    private func placeNodeHybrid(
        dict_node: [String: Any],
        screenPoint: CGPoint,
        result: @escaping FlutterResult,
        retriesLeft: Int = 10
    ) {
        guard let nodeType = dict_node["type"] as? Int, nodeType == 0,
              let nodeName = dict_node["name"] as? String,
              let uri = dict_node["uri"] as? String else {
            result(false)
            return
        }

        // Wait for the first camera frame before computing the seed
        // position. Returning early-and-placing-at-origin (the
        // previous behaviour) put the prism wherever the world
        // session originated, which the user perceived as "appears
        // inside me". Retry briefly until a frame is available.
        guard let initialPos = computeCameraRelativePosition() else {
            if retriesLeft <= 0 {
                result(false)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.placeNodeHybrid(
                    dict_node: dict_node,
                    screenPoint: screenPoint,
                    result: result,
                    retriesLeft: retriesLeft - 1
                )
            }
            return
        }

        let key = FlutterDartProject.lookupKey(forAsset: uri)
        guard let node = self.modelBuilder.makeNodeFromGltf(
            name: nodeName,
            modelPath: key,
            transformation: dict_node["transformation"] as? Array<NSNumber>
        ) else {
            self.sessionManagerChannel.invokeMethod(
                "onError",
                arguments: ["Unable to load renderable \(uri)"]
            )
            result(false)
            return
        }

        // Stage 1 — instant placement at camera-relative spot
        // (~4m forward, dropped to floor level). User sees the
        // prism right away while raycast finds the real surface
        // in the background.
        node.simdWorldPosition = initialPos
        sceneView.scene.rootNode.addChildNode(node)
        result(true)

        // Stage 2 — background raycast to find a real surface, then
        // start tracked raycast and let ARKit refine `worldTransform`
        // every frame. When the first valid hit comes in, migrate
        // the node from the camera-relative seed to the surface
        // point. From then on, drift correction is identical to the
        // pure addNodeRaycast path.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.startBackgroundRaycastMigration(
                nodeName: nodeName,
                screenPoint: screenPoint,
                retriesLeft: 30   // ~3s at 100ms intervals
            )
        }
    }

    /// Returns a world-space position ~3m forward of the current
    /// camera (horizontal projection so phone tilt doesn't skew
    /// the seed), dropped ~1.0m on Y. This is a *guess* of where
    /// the floor likely is — used only as a temporary visible seed
    /// while the background raycast finds the actual surface.
    /// Once raycast lands, the node is animated to the real
    /// position so any seed-vs-truth mismatch resolves smoothly
    /// instead of as a visible jump.
    private func computeCameraRelativePosition() -> simd_float3? {
        guard let frame = sceneView.session.currentFrame else {
            return nil
        }
        let cam = frame.camera.transform
        let camPos = simd_float3(cam.columns.3.x, cam.columns.3.y, cam.columns.3.z)
        let rawForward = simd_float3(
            -cam.columns.2.x, -cam.columns.2.y, -cam.columns.2.z
        )
        let horizontalForward = simd_normalize(simd_float3(
            rawForward.x, 0, rawForward.z
        ))
        let distance: Float = 3.0
        let pos = camPos + horizontalForward * distance
        return simd_float3(pos.x, pos.y - 1.0, pos.z)
    }

    private func startBackgroundRaycastMigration(
        nodeName: String,
        screenPoint: CGPoint,
        retriesLeft: Int
    ) {
        guard retriesLeft > 0 else { return }
        // Prefer horizontal surfaces during the first ~1.5s of
        // retries; widen to `.any` toward the end so we still
        // place if the user is right next to a wall with nothing
        // horizontal in view.
        let alignment: ARRaycastQuery.TargetAlignment =
            retriesLeft > 15 ? .horizontal : .any
        guard let query = sceneView.raycastQuery(
            from: screenPoint,
            allowing: .estimatedPlane,
            alignment: alignment
        ) else { return }

        let hits = sceneView.session.raycast(query)
        if let firstHit = hits.first {
            // Migrate the seed → real surface SMOOTHLY. A direct
            // `simdWorldPosition` assignment produced a visible
            // teleport when the seed Y-guess didn't match the real
            // floor; an SCNAction.move with ease-in-out makes the
            // adjustment feel natural — like the prism is settling
            // into place rather than snapping.
            if let target = sceneView.scene.rootNode.childNode(
                withName: nodeName, recursively: true
            ) {
                let surfacePos = SCNVector3(
                    firstHit.worldTransform.columns.3.x,
                    firstHit.worldTransform.columns.3.y,
                    firstHit.worldTransform.columns.3.z
                )
                let move = SCNAction.move(to: surfacePos, duration: 0.3)
                move.timingMode = .easeInEaseOut
                target.runAction(move)
            }
            // After the smooth migration, tracked raycast updates
            // come from ARKit's continuous refinement. Direct
            // `simdWorldPosition` writes are fine here — the
            // updates are typically sub-cm and don't read as jumps.
            let tracked = sceneView.session.trackedRaycast(query) { [weak self] (results) in
                guard let self = self,
                      let updated = results.first else { return }
                if let target = self.sceneView.scene.rootNode.childNode(
                    withName: nodeName, recursively: true
                ) {
                    let p = simd_float3(
                        updated.worldTransform.columns.3.x,
                        updated.worldTransform.columns.3.y,
                        updated.worldTransform.columns.3.z
                    )
                    target.simdWorldPosition = p
                }
            }
            if let tracked = tracked {
                trackedRaycasts[nodeName] = tracked
            }
            return
        }

        // No hit yet, retry shortly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.startBackgroundRaycastMigration(
                nodeName: nodeName,
                screenPoint: screenPoint,
                retriesLeft: retriesLeft - 1
            )
        }
    }

    /// Stable AR placement. Performs a one-shot raycast against
    /// estimated planes; on hit, builds the node + parents to scene
    /// root + spins up an `ARTrackedRaycast` whose update handler
    /// rewrites the node's world position every time ARKit refines
    /// its understanding of the surface. This is the mechanism Apple's
    /// official `Placing Objects` sample uses and what fixes the
    /// "object follows the camera as I walk around it" drift on iPhone
    /// 11. If no hit yet (ARKit still bootstrapping plane estimates),
    /// retries every 250ms up to `retriesLeft`.
    private func placeNodeViaTrackedRaycast(
        dict_node: [String: Any],
        screenPoint: CGPoint,
        retriesLeft: Int,
        result: @escaping FlutterResult
    ) {
        // Prefer horizontal surfaces (floor / ground / tabletop) so
        // the prism lands on the ground rather than on a wall or a
        // mid-air vertical estimated plane. Fall back to `.any` if
        // no horizontal surface is found within the retry budget —
        // some scenes (eg. a user standing right next to a wall)
        // genuinely have no horizontal target nearby and we'd rather
        // place imperfectly than not at all.
        let alignment: ARRaycastQuery.TargetAlignment =
            retriesLeft > 4 ? .horizontal : .any
        guard let query = sceneView.raycastQuery(
            from: screenPoint,
            allowing: .estimatedPlane,
            alignment: alignment
        ) else {
            result(false)
            return
        }

        let oneShot = sceneView.session.raycast(query)
        if let firstHit = oneShot.first {
            attachNodeWithTrackedRaycast(
                dict_node: dict_node,
                query: query,
                initialTransform: firstHit.worldTransform,
                result: result
            )
            return
        }

        if retriesLeft <= 0 {
            result(false)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.placeNodeViaTrackedRaycast(
                dict_node: dict_node,
                screenPoint: screenPoint,
                retriesLeft: retriesLeft - 1,
                result: result
            )
        }
    }

    private func attachNodeWithTrackedRaycast(
        dict_node: [String: Any],
        query: ARRaycastQuery,
        initialTransform: simd_float4x4,
        result: @escaping FlutterResult
    ) {
        guard let nodeType = dict_node["type"] as? Int, nodeType == 0 else {
            // Only NodeType.localGLTF2 is supported via raycast for now.
            // Other node types should keep using the legacy `addNode`.
            result(false)
            return
        }
        guard let nodeName = dict_node["name"] as? String,
              let uri = dict_node["uri"] as? String else {
            result(false)
            return
        }

        let key = FlutterDartProject.lookupKey(forAsset: uri)
        guard let node = self.modelBuilder.makeNodeFromGltf(
            name: nodeName,
            modelPath: key,
            transformation: dict_node["transformation"] as? Array<NSNumber>
        ) else {
            self.sessionManagerChannel.invokeMethod(
                "onError",
                arguments: ["Unable to load renderable \(uri)"]
            )
            result(false)
            return
        }

        // Anchor at the raycast hit point. Position only — orientation
        // and scale are kept from the model's own transform so the
        // prism stays gravity-up regardless of which surface the
        // raycast lands on (floor vs. wall).
        let pos = simd_float3(
            initialTransform.columns.3.x,
            initialTransform.columns.3.y,
            initialTransform.columns.3.z
        )
        node.simdWorldPosition = pos
        sceneView.scene.rootNode.addChildNode(node)

        // Continuous refinement: ARKit re-runs the raycast each frame
        // and calls back when the result changes. Updating
        // `simdWorldPosition` (only) preserves scale + orientation
        // baked in by the model builder.
        let tracked = sceneView.session.trackedRaycast(query) { [weak self] (results) in
            guard let self = self,
                  let updated = results.first else { return }
            if let target = self.sceneView.scene.rootNode.childNode(
                withName: nodeName,
                recursively: true
            ) {
                let p = simd_float3(
                    updated.worldTransform.columns.3.x,
                    updated.worldTransform.columns.3.y,
                    updated.worldTransform.columns.3.z
                )
                target.simdWorldPosition = p
            }
        }
        if let tracked = tracked {
            trackedRaycasts[nodeName] = tracked
        }

        result(true)
    }
}
