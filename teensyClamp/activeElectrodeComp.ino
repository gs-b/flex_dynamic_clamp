//routine for implementing active electrode compensation
//electrode kernels is calculated by computer and real over serial (updateElectrodeKernel())
//estimated membrane voltage is calculated by deconvolution

//transferring 16 floats sent over serial to cp.lastDataTransfer
const unsigned int electrodeKernelLenPos = 3;    //from 0, what position to start reading electrode kernel from cp.lastDataTransfer[]
const unsigned int maxElectrodeKernelLen = 50;   //max number of float pnts in kernel. to avoid dynamic allocation and potential memory overrun
                                                 //actual kernel lengths should be lower and values beyond the passed length are ignored
//state variables for electrode kernel
struct activeElectrodeCompensation {

  const unsigned int targetStepMicros = 10;  //target time step for noise injection for kernel measurement (AEC)
  bool electrodeKernelReceived = false;  //computer needs to send computed kernel
  unsigned int electrodeKernelPnts = 0; //number of points in kernel. instantaneous point is ignored
  float electrodeKernel[50] = {0.0}; //will be changed to electrodeKernelPnts 
  float lastConvolutionResult = 0;
} aec;


//updateElectrodeKernel() is called after readFloats() is called,

void updateElectrodeKernel() {
  aec.electrodeKernelPnts = cp.lastDataTransfer[electrodeKernelLenPos];
  readFloatSets(aec.electrodeKernel,aec.electrodeKernelPnts,electrodeKernelLenPos+1);
  aec.electrodeKernelReceived = true;
}

//computes the convolution result between the injected command current and the electrode kernel
//this is an estimate of the artifactual voltage reading caused by injecting current through the electrode
FASTRUN float getAecSub() {
  if (!aec.electrodeKernelReceived) { //only return non-zero if electrode kernel has been received
    return 0.0;
  }
  
  if (!sp.historyWrapped) {  //only return non-zero if the history buffer has filled once (it definitely will have by the time an electrode kernel is computed)
    return 0.0;
  }

  unsigned int i;
  aec.lastConvolutionResult = 0;
  for (i=0; i < aec.electrodeKernelPnts; i++) {
    aec.lastConvolutionResult += getCurrentHistoryPosForPnt(i);
  }
  
  return 0.0; //aec.lastConvolutionResult;
}

//returns one specified pnt for the convolution of the command history with the electrode kernel
//0 being the 1st point in the kernel (ie, skipping the instantaneous point) and the most recent current command
//this must only be called after 1) the history has been filled enough AND 2) the electrode kernel is received from the computer

//to do: consider potential for jitter in time steps and compensate by linearly interpolating the electrode kernel
//trouble is that we need cumulative time from the command to present, and that could be slow to recalculate each time step
//might be easier to re-compute the entire convolution each time step, where the individual step times could be summed
FASTRUN unsigned int getCurrentHistoryPosForPnt(int pnt) {  
  unsigned int histPos = sp.historyPos - 1 - pnt;
  //accomodate wrapping
  if (histPos < 0) {
    histPos = memLengthPnts - histPos;  //-1 gives memLengthPnts - 1, and so on
  }

  return sp.currentCmds[histPos] * aec.electrodeKernel[pnt];  
}

FASTRUN float getAecStatus() {
  if (aec.electrodeKernelReceived) {
    return 1.0;
  } else {
    return 0.0;
  }
}

