//routines for injecting (white) noise current and measuring voltage over time
//cp.lastDataTransfer //0 and 1 must be nan; 2 is type==1, input 3 as seed (4 as noise range min 5 as max), 6 as cmd to hold at after (last 3 in pA)
#include <arm_math.h>
//definitions needed for random number generator (rng)
struct ranctx { uint32_t a; uint32_t b; uint32_t c; uint32_t d; } rng;    //implements typedef struct ranctx { uint32_t a; uint32_t b; uint32_t c; uint32_t d; } ranctx;   //a structure to hold rng parameters

//variables for noise function -- currently injects noise, sends triplet info over usb serial:  dt0,vm0,inj0,dt1,vm1,inj1,...
elapsedMicros inject_dt = 0;
const unsigned int numSteps = 20000;  //should match <targetTime>*1/timeStepMicros/10^-6. 1s at 50 microseconds, 0.2s at 10 microS
const unsigned int headerLenForNoise = 4;   //number of floats sent as noise header
const unsigned int numFloatsToSend = headerLenForNoise + 2*numSteps;     //no longer need this 16-at-a-time aproach: floatsPerStandardDataTransfer*ceil((4+2*numSteps)/floatsPerStandardDataTransfer);    //round up to floatsPerStandardDataTransfer

float injectedOrDt[numSteps] = {0.0};   //float precision for flexibility; storing 12-bit int in some cases
float memVoltage[numSteps] = {0.0};
//unsigned int currDts[numSteps] = {0};
unsigned int minCurrent_12bit;
unsigned int maxCurrent_12bit;
unsigned int rangeCurrent_12bit;
unsigned int finalCurrent_12bit;
unsigned int randValRange;
unsigned int nextCurrent_12bit;
bool nextCalculated;
float scaleFactor;


FASTRUN void injectNoise() {
  raninit(cp.lastDataTransfer[3]);    //use input 4 as seed (5 as noise range min 6 as max)
  uint32_t badStepCount=0;
  int stepOvershoot,worstStepOvershoot=0;

  minCurrent_12bit = get12bitCmdForCurrent(cp.lastDataTransfer[4]);
  maxCurrent_12bit = get12bitCmdForCurrent(cp.lastDataTransfer[5]);
  finalCurrent_12bit = get12bitCmdForCurrent(cp.lastDataTransfer[6]);
  aec.targetStepMicros = (int)cp.lastDataTransfer[7];
  unsigned int noise_timeStepMicros = aec.targetStepMicros-1;    //seems to give timeStepMicros + 1 due to delays
  
  if (maxCurrent_12bit > minCurrent_12bit) {
    rangeCurrent_12bit = maxCurrent_12bit - minCurrent_12bit;
  } else {
    rangeCurrent_12bit = minCurrent_12bit - maxCurrent_12bit;
    minCurrent_12bit = maxCurrent_12bit; //for calculation start from true min and add to it
  }
  randValRange = 4096;    //n+1
  scaleFactor = (float)rangeCurrent_12bit / (float)randValRange;
  
  inject_dt = 0;
  nextCalculated = 0;
  for (size_t i=0;i<numSteps;i++) {
    if (!nextCalculated) {    //use the waiting time to calculate the next stimulus
      nextCurrent_12bit = minCurrent_12bit+((int)floor(((float)ranval12())*scaleFactor));    //constrain(1500+ (ranval12() >> 2),0,4095);   //scale to 0-1023, add 2000 so in a reasonable range
      nextCalculated = 1;
    }
    while (inject_dt < noise_timeStepMicros) {
      //w for fixed time to pass
    }
    
    //pick new injection value, write it, read vm, record time step, reset clock, increment
    injectedOrDt[i] = nextCurrent_12bit;
    analogWrite(dac_pin0,injectedOrDt[i]);
    memVoltage[i] = adc->adc0->analogReadContinuous();

    //check timing is accurate
    stepOvershoot = inject_dt - aec.targetStepMicros;
    inject_dt = 0;
    if (stepOvershoot > 0) {    //allow 1 because cant say if that elapsed as the read/write happened
      badStepCount++;
      if (stepOvershoot > worstStepOvershoot) {
        worstStepOvershoot = stepOvershoot;
      }
    }
    nextCalculated = 0;
  }
  analogWrite(dac_pin0,finalCurrent_12bit);   //set to final current cmd

  //send and do not clamp during for speed
  sendFloat(3+2*numSteps);   //0 indicate total length
  sendFloat(badStepCount);    //1
  sendFloat(worstStepOvershoot); //2 
  sendFloat(numSteps);    //3
  for (size_t i = 0; i < numSteps; i++) { sendFloat(injectedOrDt[i]); }
  for (size_t i = 0; i < numSteps; i++) { sendFloat(memVoltage[i]); }
}

//fast software random number generator from https://forum.pjrc.com/threads/48745-Teensy-3-6-Random-Number-Generator?p=164151&viewfull=1#post164151
//algorithm further described at http://www.burtleburtle.net/bob/rand/isaacafa.html
//the teensy (ARM processor) also has functions for hardware random number generator, discussed in the forum post above, where it points out they are slower

FASTRUN uint32_t ranval() {  
    uint32_t e = rng.a - rot(rng.b, 27);
    rng.a = rng.b ^ rot(rng.c, 17);
    rng.b = rng.c + rng.d;
    rng.c = rng.d + e;
    rng.d = e + rng.a;
    return rng.d;
}

FASTRUN void raninit( uint32_t seed ) {
    uint32_t i;
    rng.a = 0xf1ea5eed, rng.b = rng.c = rng.d = seed;
    for (i=0; i<20; ++i) {
        (void)ranval();
    }
}

FASTRUN uint32_t rot(uint32_t x,uint32_t k) {   //implements #define rot(x,k) (((x)<<(k))|((x)>>(32-(k))))   //function definition
  return (((x)<<(k))|((x)>>(32-(k))));
}

//my own addition to rescale to 12-bit, output it still 32-bit but range is 0-4095
FASTRUN uint32_t ranval12() {  
  return ranval() >> 20;   //shift (right) by 32-12 = 20 bits, rescaling 0 to -1+2^16 to 0 to 4095 (=-1+2^12)
}


//record step change in arbitrary conductance from 0 to sizeProportion
FASTRUN void recordStep() {
  unsigned int stepMicros = cp.lastDataTransfer[3];  //when step should start. should be < numSteps * meanTimeStep or 20000*3 microsecs = 60,000 micros
  float baselineCurrent = cp.lastDataTransfer[4];    //current before step
  float stepCurrent = cp.lastDataTransfer[5];        //current during step

  //store previous dc current and set to baseline
  float prevCurrent = cp.dcOffset_pA;
  cp.dcOffset_pA = baselineCurrent;

  //run a few steps to get to new steady state dcOffset_pA
  for (size_t i = 0; i < 100; i++) { clampStep(); }

  inject_dt = 0;
  for (size_t i=0; i<numSteps; i++) {
    if (inject_dt >= stepMicros) {
      cp.dcOffset_pA = stepCurrent;
    }
    clampStep();
    injectedOrDt[i] = sp.dts[sp.historyPos]; 
    memVoltage[i] = sp.lastVm;
  }

  cp.dcOffset_pA = prevCurrent; clampStep();  //return to old state

  sendFloat(1 + 2*numSteps);
  sendFloats(injectedOrDt,numSteps,true);
  sendFloats(memVoltage,numSteps,true);
}



