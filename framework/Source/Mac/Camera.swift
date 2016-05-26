import Foundation
import AVFoundation

let initialBenchmarkFramesToIgnore = 5

public class Camera: NSObject, ImageSource, AVCaptureVideoDataOutputSampleBufferDelegate {
    public var orientation:ImageOrientation
    public var runBenchmark:Bool = false
    public var logFPS:Bool = false

    public let targets = TargetContainer()
    let captureSession:AVCaptureSession
    let inputCamera:AVCaptureDevice
    let videoInput:AVCaptureDeviceInput!
    let videoOutput:AVCaptureVideoDataOutput!
    var supportsFullYUVRange:Bool = false
    let captureAsYUV:Bool
    let yuvConversionShader:ShaderProgram?
    let frameRenderingSemaphore = dispatch_semaphore_create(1)
    let cameraProcessingQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH,0)
    let audioProcessingQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW,0)

    var numberOfFramesCaptured = 0
    var totalFrameTimeDuringCapture:Double = 0.0
    var framesSinceLastCheck = 0
    var lastCheckTime = CFAbsoluteTimeGetCurrent()

    public init(sessionPreset:String, cameraDevice:AVCaptureDevice? = nil, orientation:ImageOrientation = .Portrait, captureAsYUV:Bool = true) throws {
        self.inputCamera = cameraDevice ?? AVCaptureDevice.defaultDeviceWithMediaType(AVMediaTypeVideo)
        self.orientation = orientation
        self.captureAsYUV = captureAsYUV
        
        self.captureSession = AVCaptureSession()
        self.captureSession.beginConfiguration()

        do {
            self.videoInput = try AVCaptureDeviceInput(device:inputCamera)
        } catch {
            self.videoInput = nil
            self.videoOutput = nil
            self.yuvConversionShader = nil
            super.init()
            throw error
        }
        if (captureSession.canAddInput(videoInput)) {
            captureSession.addInput(videoInput)
        }
        
        // Add the video frame output
        videoOutput = AVCaptureVideoDataOutput()
        videoOutput.alwaysDiscardsLateVideoFrames = false
        
        if captureAsYUV {
            supportsFullYUVRange = false
            let supportedPixelFormats = videoOutput.availableVideoCVPixelFormatTypes
            for currentPixelFormat in supportedPixelFormats {
                if ((currentPixelFormat as! NSNumber).intValue == Int32(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)) {
                    supportsFullYUVRange = true
                }
            }
            
            if (supportsFullYUVRange) {
                yuvConversionShader = crashOnShaderCompileFailure("Camera"){try sharedImageProcessingContext.programForVertexShader(defaultVertexShaderForInputs(2), fragmentShader:YUVConversionFullRangeFragmentShader)}
                videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey:NSNumber(int:Int32(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange))]
            } else {
                yuvConversionShader = crashOnShaderCompileFailure("Camera"){try sharedImageProcessingContext.programForVertexShader(defaultVertexShaderForInputs(2), fragmentShader:YUVConversionVideoRangeFragmentShader)}
                videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey:NSNumber(int:Int32(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange))]
            }
        } else {
            yuvConversionShader = nil
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey:NSNumber(int:Int32(kCVPixelFormatType_32BGRA))]
        }

        if (captureSession.canAddOutput(videoOutput)) {
            captureSession.addOutput(videoOutput)
        }
        captureSession.sessionPreset = sessionPreset
        captureSession.commitConfiguration()

        super.init()
        
        videoOutput.setSampleBufferDelegate(self, queue:cameraProcessingQueue)
    }
    
    public func captureOutput(captureOutput:AVCaptureOutput!, didOutputSampleBuffer sampleBuffer:CMSampleBuffer!, fromConnection connection:AVCaptureConnection!) {
        guard (dispatch_semaphore_wait(frameRenderingSemaphore, DISPATCH_TIME_NOW) == 0) else { return }
        let startTime = CFAbsoluteTimeGetCurrent()

        let cameraFrame = CMSampleBufferGetImageBuffer(sampleBuffer)!
        let bufferWidth = CVPixelBufferGetWidth(cameraFrame)
        let bufferHeight = CVPixelBufferGetHeight(cameraFrame)
        let currentTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        
        CVPixelBufferLockBaseAddress(cameraFrame, 0)
        sharedImageProcessingContext.runOperationAsynchronously{
            let cameraFramebuffer:Framebuffer

            if (self.captureAsYUV) {
                let luminanceFramebuffer = sharedImageProcessingContext.framebufferCache.requestFramebufferWithProperties(orientation:self.orientation, size:GLSize(width:GLint(bufferWidth), height:GLint(bufferHeight)), textureOnly:true)
                luminanceFramebuffer.lock()
                glActiveTexture(GLenum(GL_TEXTURE0))
                glBindTexture(GLenum(GL_TEXTURE_2D), luminanceFramebuffer.texture)
                glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_LUMINANCE, GLsizei(bufferWidth), GLsizei(bufferHeight), 0, GLenum(GL_LUMINANCE), GLenum(GL_UNSIGNED_BYTE), CVPixelBufferGetBaseAddressOfPlane(cameraFrame, 0))

                let chrominanceFramebuffer = sharedImageProcessingContext.framebufferCache.requestFramebufferWithProperties(orientation:self.orientation, size:GLSize(width:GLint(bufferWidth), height:GLint(bufferHeight)), textureOnly:true)
                chrominanceFramebuffer.lock()
                glActiveTexture(GLenum(GL_TEXTURE1))
                glBindTexture(GLenum(GL_TEXTURE_2D), chrominanceFramebuffer.texture)
                glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_LUMINANCE_ALPHA, GLsizei(bufferWidth / 2), GLsizei(bufferHeight / 2), 0, GLenum(GL_LUMINANCE_ALPHA), GLenum(GL_UNSIGNED_BYTE), CVPixelBufferGetBaseAddressOfPlane(cameraFrame, 1))

                cameraFramebuffer = sharedImageProcessingContext.framebufferCache.requestFramebufferWithProperties(orientation:.Portrait, size:GLSize(width:GLint(bufferWidth), height:GLint(bufferHeight)), textureOnly:false)
                
                let conversionMatrix:Matrix3x3
                if (self.supportsFullYUVRange) {
                    conversionMatrix = colorConversionMatrix601FullRangeDefault
                } else {
                    conversionMatrix = colorConversionMatrix601Default
                }
                convertYUVToRGB(shader:self.yuvConversionShader!, luminanceFramebuffer:luminanceFramebuffer, chrominanceFramebuffer:chrominanceFramebuffer, resultFramebuffer:cameraFramebuffer, colorConversionMatrix:conversionMatrix)
            } else {
                cameraFramebuffer = sharedImageProcessingContext.framebufferCache.requestFramebufferWithProperties(orientation:self.orientation, size:GLSize(width:GLint(bufferWidth), height:GLint(bufferHeight)), textureOnly:true)
                glActiveTexture(GLenum(GL_TEXTURE0))
                glBindTexture(GLenum(GL_TEXTURE_2D), cameraFramebuffer.texture)
                glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_RGBA, GLsizei(bufferWidth), GLsizei(bufferHeight), 0, GLenum(GL_BGRA), GLenum(GL_UNSIGNED_BYTE), CVPixelBufferGetBaseAddress(cameraFrame))
            }
            CVPixelBufferUnlockBaseAddress(cameraFrame, 0)
            
            cameraFramebuffer.timingStyle = .VideoFrame(timestamp:Timestamp(currentTime))
            self.updateTargetsWithFramebuffer(cameraFramebuffer)
            
            if self.runBenchmark {
                self.numberOfFramesCaptured += 1
                if (self.numberOfFramesCaptured > initialBenchmarkFramesToIgnore) {
                    let currentFrameTime = (CFAbsoluteTimeGetCurrent() - startTime)
                    self.totalFrameTimeDuringCapture += currentFrameTime
                    print("Average frame time : \(1000.0 * self.totalFrameTimeDuringCapture / Double(self.numberOfFramesCaptured - initialBenchmarkFramesToIgnore)) ms")
                    print("Current frame time : \(1000.0 * currentFrameTime) ms")
                }
            }
        
            if self.logFPS {
                if ((CFAbsoluteTimeGetCurrent() - self.lastCheckTime) > 1.0) {
                    self.lastCheckTime = CFAbsoluteTimeGetCurrent()
                    print("FPS: \(self.framesSinceLastCheck)")
                    self.framesSinceLastCheck = 0
                }
                
                self.framesSinceLastCheck += 1
            }

            dispatch_semaphore_signal(self.frameRenderingSemaphore)
        }
    }

    public func startCapture() {
        self.numberOfFramesCaptured = 0
        self.totalFrameTimeDuringCapture = 0

        if (!captureSession.running) {
            captureSession.startRunning()
        }
    }
    
    public func stopCapture() {
        if (!captureSession.running) {
            captureSession.stopRunning()
        }
    }
    
    public func transmitPreviousImageToTarget(target:ImageConsumer, atIndex:UInt) {
        // Not needed for camera inputs
    }
}
