//routine for implementing active electrode compensation
//electrode kernels is calculated by computer and real over serial (updateElectrodeKernel())
//estimated membrane voltage is calculated by deconvolution

//transferring 16 floats sent over serial to cp.lastDataTransfer
const unsigned int electrodeKernelLenPos = 3;    //from 0, what position to start reading electrode kernel from cp.lastDataTransfer[]
const unsigned int maxElectrodeKernelLen = 80;   //max number of float pnts in kernel. to avoid dynamic allocation and potential memory overrun
                                                 //actual kernel lengths should be lower and values beyond the passed length are ignored
const unsigned int maxInterpolatedKernelLen = 500;  //interpolate to 1 microsecond, max 490 total (first 10 microseconds ignored)

//state variables for electrode kernel
struct activeElectrodeCompensation {

  unsigned int targetStepMicros = 5;  //target time step for noise injection for kernel measurement (AEC). can be altered by GUI during noise injection
  const float invTargetStepMicros = 1/(float)targetStepMicros;
  bool electrodeKernelReceived = false;  //computer needs to send computed kernel
  unsigned int electrodeKernelPnts = 0; //number of points in kernel. instantaneous point is ignored
  float electrodeKernel[maxElectrodeKernelLen] = {0.0}; //holds the actual electrode kernel
  float interpElectrodeKernel[maxInterpolatedKernelLen] = {0.0};  //holds the electrode kernel interpolated to 1 microsecond resolution
  float lastConvolutionResult = 0;
  unsigned int kernelMicros = 0;
  unsigned int ignoreMicros = 0;
} aec;


//updateElectrodeKernel() is called after readFloats() is called,

void updateElectrodeKernel() {
  //read the kernel from serial
  aec.electrodeKernelPnts = cp.lastDataTransfer[electrodeKernelLenPos];
  aec.ignoreMicros = cp.lastDataTransfer[electrodeKernelLenPos+1];
  readFloatSets(aec.electrodeKernel,aec.electrodeKernelPnts,electrodeKernelLenPos+2);
  aec.electrodeKernelReceived = true;
  aec.kernelMicros = aec.electrodeKernelPnts * aec.targetStepMicros;  

  //interpolate the kernel to 1 microsecond resolution
  for (size_t i = 0; i < aec.kernelMicros; i++) {
    aec.interpElectrodeKernel[i] = interp(aec.electrodeKernel,aec.invTargetStepMicros,i);
  }
}

//computes the convolution result between the injected command current and the electrode kernel
//this is an estimate of the artifactual voltage reading caused by injecting current through the electrode
int histPos; unsigned int totalDt;
FASTRUN float getAecSub() {
  aec.lastConvolutionResult = 0.0;

  //only return non-zero if AEC checkbox is on in GUI (cp.aec represents here), if electrode kernel has been received, and if history position has wrapped (almost always true -- maybe should drop for speed)
  if (!cp.aec || !aec.electrodeKernelReceived || !sp.historyWrapped) {
    return aec.lastConvolutionResult;                        //and if the history buffer has filled once (it definitely will have by the time an electrode kernel is computed)
  }
  
  histPos = sp.historyPos; //position in history buffer
  totalDt = sp.dts[histPos]; //use last dt as representative of likely dt for next clamp step. Could try sp.dt instead
  do {
    if (totalDt >= aec.kernelMicros) { return aec.lastConvolutionResult; } //check if dt is beyond kernel length
    
    if (totalDt > aec.ignoreMicros) {   //don't start calculation til a fill kernel time step
     aec.lastConvolutionResult += sp.currentCmds[histPos] * aec.interpElectrodeKernel[totalDt];
    }

    //iterate
    histPos--; if (histPos < 0) { histPos = memLengthPnts - 1; } //wrap if needed
    totalDt += sp.dts[histPos];
  } while (true);
  
}

//linear interpolation for a value in an array inArray of length pnts at an offset x
//where points are evenly spaced by 1/indDx starting from x = 0
//invDx is precalculated to reduce the number of divisions, though speed isn't critial where this is called
FASTRUN float interp(float inArray[], float invDx, float x) {
  float pos = x * invDx;  
  int p0 = floor(pos);
  int p1 = p0 + 1;
  float offset_p0 = pos - ((float)p0);
  return inArray[p0]*(1-offset_p0) + inArray[p1]*offset_p0;
}


FASTRUN float getAecStatus() {
  if (aec.electrodeKernelReceived) {
    return 1.0;
  } else {
    return 0.0;
  }
}

