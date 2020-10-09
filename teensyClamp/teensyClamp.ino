//TEENSY (3.6) DYNAMIC CLAMP FOR IGOR. Requires a Teensy 3.6 (may work for future Teensy versions that have two ADCs) To use:
//1. Check your pin wiring and change PIN ASSIGNMENTS below. A pin for each of the two ADCs and a DAC pin is needed
//2. Calibrate with testExternalCond3.ino and, in Igor, teensyCal_doCals() in teensyCalibration.ipf. Beforehand, update ks_teensyCom = "COM21" in that file
//3. Load this sketch and run teensy_clamp()(in teensyCalibration.ipf) in Igor

#include <ADC.h>
#include <array>

//PIN ASSIGNMENTS. These are all the user should need to change
const int adc0_pin0 = A0;     // ADC0 -- this should read Vm
const int adc1_pin0 = A19;    // ADC1 -- this is an input proportional to the size of the conductance (actually clipped for 0.5 - 2.5V)
const int dac_pin0 = A21;         // DAC0
const int led_pin = 13;    //pin of LED on teensy, usually 13.

//CALIBRATION DATA. Calibration generated with sketch testExternalCond3.ino and, in Igor, teensyCal_doCals() in teensyCalibration.ipf
//These can be set here instead but any calibration data sent from Igor will overwrite as it is assumed that is more current
const float input_slope_default = 7.8236; //from input-side calibration: (Mem voltage)=((teensyRead)-(offset))/(slope)
const float input_offset_default = 2452.6; //from input-side calibration: (Mem voltage)=((teensyRead)-(offset))/(slope)
const float output_slope_default = -0.68578;  //from output-side calibration: (teensyWriteVal)=((currentVal in pA)-(offset))/(slope)
const float output_offset_default = 1327.7; //from output-side calibration: (teensyWriteVal)=((currentVal in pA)-(offset))/(slope)

//other constants
const unsigned int numVmVals = 4096;    //this is the number of possible voltage readings given 12-bit analog input
const int memLengthPnts = 1000;    //how many previous vm readings should be held in memory (for active electrode compensation
const unsigned int comBaud = 115200;    //baud rate for Serial USB. should match Igor
const unsigned int floatsPerStandardDataTransfer = 16;   //how many float items are expected each read. should match Igor
const int bytesExpectedPerStandardDataTranfer = 4*floatsPerStandardDataTransfer;    //should be 4*floatsPerStandardDataTransfer, each 32-bit float is 4 bytes!
const float nanVal = 0x7FC00000;
  
//a structure to hold CONTROL PARAMETERS. (These are just combined into a struct for readability)
  //These affect what the teensy is doing from moment to moment and can be changed over serial I/O
  //These generally correspond to (Igor) GUI checboxes (for bool variables) or Igor setVars/sliders (float variables)
  //all are initialized to zero in setup()
struct controlParameters {    //name of struct type
  //data transfer array: always stores most recent set of float data received over serial USB.
  float lastDataTransfer[floatsPerStandardDataTransfer];    //filled by reading serial I/O, sets items below

  //calibration data (when caribration data is sent, these are positions 0 to 3 in lastDataTransfer, the rest are nan
  float input_slope; //from input-side calibration: (Mem voltage)=((teensyRead)-(offset))/(slope). initialized to input_slope_default
  float input_offset; //from input-side calibration: (Mem voltage)=((teensyRead)-(offset))/(slope). initialized to input_offset_default
  float output_slope;  //from output-side calibration: (teensyWriteVal)=((currentVal in pA)-(offset))/(slope). initialized to output_slope_default
  float output_offset; //from output-side calibration: (teensyWriteVal)=((currentVal in pA)-(offset))/(slope). initialized to output_offset_default  

  //standard Serial USB control data. usually positions 1 onward (0 is nan to indicate that these data are being sent)
  bool isRunning;         //does the teensy do anything during clamp steps? Timing is also relative to running start
  bool leakClamping;      //is the teensy in dynamic clamp mode for a leak current? (leakClamping checkbox in Igor)
  bool dynamicClampingArbitraryInput;  //is the teensy in dynamic clamp mode for an arbitrary conductance waveform? (arbClamping checkbox in Igor)
  bool aec; //is the teensy in AEC clamp mode? (controlled by AEC checkbox and requires electrode kernel has been sent to teensy)
  float dcOffset_pA; //apply any dc offset? (dc_pA slider in Igor)
  float leak_nS;       //apply any leak conductance? (leak_nS slider in Igor)
  float leak_mV;      //reversal potential of the leak conductance? (leak_mV slider in Igor). leak current is simply = (Vmem - leak_mV)*leak_nS (has units of pA like output-side calibration)
  float junctionPotential;   //set a junction potential: Value is ADDED to the voltage reading to give the true voltage, so it's usually negative in whole cell.
                             //note that this is very slightly inefficient for computation, could pre-bake this into i(v) relation and leak offset 
  int arbitraryIvOffsetDueToJP;    //junction potential will slide position in arbitrary I(V).
  
  
  //I(V) relation for arbitrary clamp conductance. Started by sending fully-real-values Serial I/O for lastDataTransfer. Then multiple rounds are read
  float ivVals[numVmVals];
  float ivMultiplier; //multiplies i(v)
  
} cp; //name of struct instance                             

//A structure to hold STATE PARAMETERS. These are not directly set from Serial, they are used in calculation from moment to moment or reflect moment to moment behavior
struct stateParameters {
  
  //from or for the dynamic clamp calculation
  unsigned int conductanceMultiplier12bit;  //12-bit reading from pin that gets conductance multiplier signal
  float lastArbitraryMultiplier;   //these variables track system state and are reported back over serial i/o
  unsigned int lastVmPinReading;  //12-bit reading from pin that monitors membrane voltage
  float lastLeakCurrent;
  float lastArbitraryCurrent_raw;   //based on IV relation, not multiplied by lastArbitraryMultiplier
  float lastArbitraryCurrent_scaled;  //lastArbitraryCurrent_raw*lastArbitraryMultiplier
  float lastTotalCurrent;    //what's actually injected
  unsigned int current_cmd12bit;   //what is the DAC command to apply that total current

  //timing & timing info
  unsigned int startMillis;         //start of setup()
  unsigned int lastReadMillis;      //record time of last reading, relative to startMillis. Handled in getTargetCurrent()
  unsigned int calibrationDataReceived;   //monitors how many times calibration data has been received over serial i/o
  bool wasPaused;                   //was clamp recently paused? controls whether a time step is recorded for mean,sdev,variance of dt. Don't want to record when reading an iv relation

  //memory
  elapsedMicros dt;                       // will track time between each vm reading  
  float currentCmds[memLengthPnts];    //tracks previous vm readings. Handled in getTargetCurrent()
  unsigned int dts[memLengthPnts];     //tracks dt since last reading. Handled in getTargetCurrent()
  int historyPos;             //tracks current position in these arrays so they act like circular buffers. Handled in getTargetCurrent()
  float lastVm;
  bool historyWrapped;    //tracks whether the currentCmds and dts history buffer has wrapped at least once, meaning it has filled
} sp;

//OTHER VARIABLES
ADC *adc = new ADC(); //ADC object

void setup() {
  //set resolution and pin modes
  analogReadResolution(12);
  analogWriteResolution(12);  //may be redundant with adc->adc0->setResolution(12);  
  pinMode(dac_pin0,OUTPUT);
  pinMode(led_pin,OUTPUT);
  pinMode(adc0_pin0,INPUT);
  pinMode(adc1_pin0,INPUT);

  //flash the LED to indicate load worked
  Serial.begin(comBaud);
  digitalWrite(led_pin,HIGH);
  delay(500);
  digitalWrite(led_pin,LOW);

  //set up ADCs, see https://forum.pjrc.com/threads/25532-ADC-library-with-support-for-Teensy-4-3-x-and-LC
  adc->adc0->setAveraging(1);  //in some testing, set averaging 8 vs 1 has at most 30% increase in sdev. testing not exhaustive so far
  adc->adc0->setResolution(12);  //some docs suggest 13-bit might be supported
  adc->adc0->setConversionSpeed(ADC_CONVERSION_SPEED::VERY_HIGH_SPEED); //have not explored speed/accuracy trade-offs
  adc->adc0->setSamplingSpeed(ADC_SAMPLING_SPEED::VERY_HIGH_SPEED);
  adc->adc0->startContinuous(adc0_pin0);    //will be reading continuously.. found to be far less noisy than not doing this and using analogRead()

  adc->adc1->setAveraging(1); 
  adc->adc1->setResolution(12);  
  adc->adc1->setConversionSpeed(ADC_CONVERSION_SPEED::VERY_HIGH_SPEED);
  adc->adc1->setSamplingSpeed(ADC_SAMPLING_SPEED::VERY_HIGH_SPEED);
  adc->adc1->startContinuous(adc1_pin0);    //will be reading continuously

  //initialize structs and runs first vm measurement
  initControlParams();
  initStateParams();
  clamp();    //just get started with target current injection 0
}

//main loop reacts to serial input, which is always 16 single float point units (i.e., 16 bytes, 256 bits, the limit for serial input to the teensy)
//when not receiving, it's: 1) in clamp mode or 2) receiving an iv relation, which is 4096 float point units, so that takes many rounds of serial input
FASTRUN void loop() {
  //step A: continue the clamp routine. clamp() runs on a tighter loop, only broken for serial input
  clamp();   
  
  //step B: clamp breaks on a full serial input (16 floats), which is handled here:
  readFloats(0);   //read serial input into lastDataTransfer while doing clamp steps, don't respond over seral yet (do so later here)

  //different reactions based on the form of serial input
  //0) 0th value is nan: Normal settings update
  //1) all real: iv relation update
  //2) 0th and 1st nan: various other updates depending on value 2nd value
    //2nd value == 0: calibration update
    //2nd value == 1: start noise injection
    //2nd value == 2: starting send of AEC kernel
  if (isnan(cp.lastDataTransfer[0])) {    
    if (!isnan(cp.lastDataTransfer[1])) {  //case 0 (0 nan, 1 real): normal settings update
      updateState();    //normal state update from serial
      report(1);    //normal report back over serial       
    } else {                               //case 2 (0 and 1 nan): various possible updates
      serialSpecialCaseUpdate();           //handle determining the update type and doing it
    }
  } else {                                 //case 1 (0 real, assume all real): iv update
    readFloatSets(cp.ivVals,numVmVals,0);   //read this serial input as the first set of iv values, prepare to load more 
  }  //note that iv is not handled like special cases because its time consuming and this minimizes the number of transfers, as the first transfer can carry 16 real float values
}

//handle various potential updates depending on value of cp.lastDataTransfer[2]
//type == 0: force calibration values (4 floats)
//type == 1: run noise (1 float)
//type == 2: electrode kernel transfer (variable length depending on next point)
//type == 3: record step. no updates from GUI allowed until stop
//type == 4: input-side calibration over serial i/o (returns a set of vm pin readings)
//type == 5: output-side calibration over serial i/o (sets output DAC to value from 0-4095 in cp.lastDataTransfer[3]; does nothing out of range)
//type == 6: follow mode for calibration (initiate and stop with with cp.lastDataTransfer[3] == 0 or 1, respectively) -- NOT RECENTLY TESTED
FASTRUN void serialSpecialCaseUpdate() {
  int type = (int)cp.lastDataTransfer[2];

  if (type == 0) { updateCalibration(); report(1); return; } //in this file
  if (type == 1) { injectNoise(); report(1); return; } //in injectNoise
  if (type == 2) { updateElectrodeKernel(); return; } //in activeElectrodeComp; updateElectrodeKernel does its own responding
  if (type == 3) { recordStep(); return; }
  if (type == 4) { sendInputCalibrationReads(); return; }   //return vm pin readings over serial output to computer
  if (type == 5) { writeForOutputCalibration(); return; }   //writes value in cp.lastDataTransfer[3], write mode ends if that valus is above 5000 (0-4095 acceptable)
  if (type == 6) { setFollowModeForCalibration(); return; } //the latter doesn't really do anything as any serial i/o would interrupt follow, but it's nice to program an expected input
}


//DYNAMIC CLAMP FUNCTIONS

//standard clamp routine on a tight loop -- only break for serial input handling
FASTRUN void clamp() {  //runs until serial I/O. Unless the serial i/o shuts off clamp, loop() will call this function again as soon as the i/o is dealt with
  do {
    clampStep();
  } while (Serial.available() < bytesExpectedPerStandardDataTranfer);
}

FASTRUN void clampStep() {
  if (!cp.isRunning) { return; }  //only take a clamp step if running
  
  calcTargetCurrent(); //sets sp.lastTotalCurrent as the sum of leak conductance current and arbitrary conductance current
  sp.current_cmd12bit = get12bitCmdForCurrent(sp.lastTotalCurrent);
  analogWrite(dac_pin0,sp.current_cmd12bit);
  updateCurrentHistory();//store current command and, if running AEC, update pipette response
}

int ivPos; //just going to keep this pre-declared as global
FASTRUN void calcTargetCurrent() {  //sets sp.lastTotalCurrent for new target current based on vm and conductances. Reads vm, calculates current from cond relation
  //read and calculate vm
  sp.lastVmPinReading = adc->adc0->analogReadContinuous();
  sp.lastVm = getVmFrom12bitReading(sp.lastVmPinReading,false) - getAecSub();
    //note: updateCurrentHistory() is called in clamp() for a better reflection of the total dt step time
  
  //leak component
  if (cp.leakClamping) {
    sp.lastLeakCurrent = -(sp.lastVm - cp.leak_mV)*cp.leak_nS;    //just ohms law, - for whole cell: inward current depolarized
  } else {
    sp.lastLeakCurrent = 0;
  }

  //arbitrary-clamp component
  if (cp.dynamicClampingArbitraryInput) {
    ivPos = (unsigned int)(sp.lastVmPinReading + cp.arbitraryIvOffsetDueToJP);
    if (ivPos > 4095) {
      ivPos = 4095;   //constrain to 0-4095 (is 0 or greater because unsigned
    }
    sp.lastArbitraryCurrent_raw = cp.ivVals[ivPos]; //removed negative sign
    sp.lastArbitraryCurrent_scaled = sp.lastArbitraryCurrent_raw * getConductanceMultiplier() * cp.ivMultiplier; //ivVals are pre-scaled to a value from 0 - 4095 during calibration
  } else {
    sp.lastArbitraryCurrent_raw = 0;
    sp.lastArbitraryCurrent_scaled = 0;
  }

  //total -- this will be returned
  sp.lastTotalCurrent = cp.dcOffset_pA + sp.lastLeakCurrent + sp.lastArbitraryCurrent_scaled; 
}

FASTRUN int get12bitCmdForCurrent(float current) {   //current in pA, from output-side calibration: (teensyWriteVal)=((currentVal in pA)-(offset))/(slope)
  return (int) ( (current - cp.output_offset) / cp.output_slope );
}

//  convert from teensy reads with: (Mem voltage)=((teensyRead)-(offset))/(slope); (Mem voltage)=((teensyRead)-(2452.6))/(7.8236)
//  then ADD the usually negative junction potential to get the actual membrane voltage
FASTRUN float getVmFrom12bitReading(int vmPinReading, bool ignoreJunctionPotential) {   //vm in mV

  float result = ( ((float)vmPinReading) - cp.input_offset ) / cp.input_slope;

  if (!ignoreJunctionPotential) {
    result += cp.junctionPotential;
  }

  return result;
} 

FASTRUN float get12BitReadingChangeForVmChange(float deltaVm) {
  return deltaVm * cp.input_slope;
}

//currently set to anticipate modulation from 0V to 3.1025V  //0.3 to 2.8V for a 2.5V range. Above 3.3V will damage teensy! 2.5V range is nice because becomes 0-1 by multiplying by 0.4
const int minForCondSize = 0;//372;    //what range from 0 to 4095 for minimumal activation of conductance (zero point, below this also get zero). 372 is ~0.3V
const int maxForCondSize = 3850;   //what range from 0 to 4095 for maximal activation of conductance (max point, above this also gives max conductance). 3474 is ~2.8V 
const int rangeForCondSize = maxForCondSize-minForCondSize;//3102;
FASTRUN float getConductanceMultiplier() {    //0-1 proportional to size of conductance
  sp.conductanceMultiplier12bit = adc->adc1->analogReadContinuous();
  sp.lastArbitraryMultiplier = constrain(((float)sp.conductanceMultiplier12bit - (float)minForCondSize)/(float)rangeForCondSize,0,1);   //0-1 value. see notes above for explanation  
  return sp.lastArbitraryMultiplier;
}

FASTRUN void updateCurrentHistory() {
  sp.historyPos++;    //iterate
  if (sp.historyPos >= memLengthPnts) {   //this seems potentially faster than modulo..
    sp.historyPos = 0;
    if (!sp.historyWrapped) {
      sp.historyWrapped = true;
    }
  }  
  
  sp.lastReadMillis = millis() - sp.startMillis;    //record time of this reading relative to running start
  sp.currentCmds[sp.historyPos] = sp.lastTotalCurrent;     //sp.lastVm is updated in calcTargetCurrent()
  sp.dts[sp.historyPos] = sp.dt;
  if (sp.wasPaused) { sp.wasPaused = 0; } //when receiving i(v) data or not clamping, dt could get long and don't want to include in calculation
  else { rs_push(sp.dt); }   //push to track dt mean and variance (in stats.ino). rs_init() must have been run already (it is in initStateParams)
  sp.dt = 0;  
}

void initStateParams() {    //state params initialization + first vm measurement, first current output, on system start
  //STATE PARAMETERS
  //timing- and memory-related
  sp.startMillis = millis();
  sp.calibrationDataReceived = 0;   //monitors how many times calibration data has been received over serial i/o
  memset(sp.currentCmds,0,sizeof(sp.currentCmds));  //initialize currentCmds to zero
  memset(sp.dts,0,sizeof(sp.dts));
  sp.historyPos = -1;             //tracks current position in these arrays so they act like circular buffers
  sp.historyWrapped = false;        //tracks whether history buffer has wrapped around at least once, meaning AEC has (more than) enough data to work with
  rs_init();                    //get ready to track dt mean and variance (in stats.ino)
  
  //start reading and write 0 current output  
  sp.wasPaused = 1;   //dont want to count first time step in running mean, sdev, var dt
  sp.dt = 0;
 }


//based on Serial input, update state variables
FASTRUN void updateState() {
  bool wasRunning = cp.isRunning;
  cp.isRunning = cp.lastDataTransfer[1] > 0;
  if (!wasRunning && cp.isRunning) { sp.startMillis = millis(); }   //running just started, reset timer
  cp.leakClamping = cp.lastDataTransfer[2] > 0;
  cp.dynamicClampingArbitraryInput = cp.lastDataTransfer[3] > 0;
  cp.aec = cp.lastDataTransfer[4] > 0 ;
  cp.dcOffset_pA = cp.lastDataTransfer[5];
  cp.leak_nS = cp.lastDataTransfer[6];
  cp.leak_mV = cp.lastDataTransfer[7];
  cp.junctionPotential = cp.lastDataTransfer[8];
  cp.ivMultiplier = cp.lastDataTransfer[9];
  //position 0 MUST be nan and position 5 MUST be real, currently. This and other positions could be used
  //with the potential need for modifications to loop() and updateCalibration() 
  //positions 10-15 are expected to be nan and can be used to send additional parameters

  cp.arbitraryIvOffsetDueToJP = (int)round(get12BitReadingChangeForVmChange(cp.junctionPotential)); //imperfect, but better than noting. Could interpolate in future
}

FASTRUN void updateCalibration() {
  //in this transfer, 0th is nan, 1st nan, 2nd 0 to indicate calibration update
  //data starts at 3
  cp.input_slope = cp.lastDataTransfer[3];
  cp.input_offset = cp.lastDataTransfer[4];
  cp.output_slope = cp.lastDataTransfer[5];
  cp.output_offset = cp.lastDataTransfer[6];

  sp.calibrationDataReceived = 1;
}

void initControlParams() {   //control parameters setup (these will be reset by serial i/o eventually; except possible for ivVals
  memset(cp.lastDataTransfer,0,sizeof(cp.lastDataTransfer));    //initialize all values to zero
  cp.input_slope = input_slope_default;
  cp.input_offset = input_offset_default;
  cp.output_slope = output_slope_default;
  cp.output_offset = output_offset_default;
  cp.isRunning = 0;
  cp.leakClamping = 0;     
  cp.dynamicClampingArbitraryInput = 0;  
  cp.dcOffset_pA = 0; 
  cp.leak_nS = 0;       
  cp.leak_mV = 0;    
  cp.junctionPotential = 0;    
  memset(cp.ivVals,0,sizeof(cp.ivVals)); 
}
