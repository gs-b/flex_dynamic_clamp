//serial i/o

//read an arbitrary number of floats. Has check points to overcome the 64 byte limit of the Serial input (i.e., cant receive more than 16 32-bit float values at a time)
//clamps during down time, overhead appears to add ~1-2 microseconds (clamp steps are generally 2-4 microseconds)
const float readFloatsTimeOutSecs=1;
FASTRUN void readFloatSets(float intoArray[], unsigned int intoArraySize, unsigned int initalOffset) {
  
  unsigned int numRead = 0, numRemaining = intoArraySize, numToReadNow, offsetVal;
  unsigned int timeOutMillis = readFloatsTimeOutSecs*1000, lastAttemptMillis = millis();  //current time since 1970 in seconds
  bool moreToRead = 1,firstIteration = 1;   //already loaded the first set, so don't try to load more yet
  do {
    numToReadNow = min(numRemaining,floatsPerStandardDataTransfer);   //read whatever is left, up to the maximum that can be read

    //first iteration: skip loading, handle initialOffset
    if (firstIteration) {
      offsetVal = initalOffset;

    //if it's not the first iteration, load data (cannot have an offset)
    } else { //
      offsetVal = 0;
      if ( Serial.available() < bytesExpectedPerStandardDataTranfer) {
        if ( millis() < (lastAttemptMillis + timeOutMillis) ) { clampStep(); continue; } //clampStep(); continue; } 
        else { report(-1); return; }
      }
      readFloats(1);   //report status so computer knows to send next set
      lastAttemptMillis = millis();
    }

    //transfer data to iv relation
    for (size_t i = offsetVal ; i < numToReadNow; i++) {
      intoArray[numRead] = cp.lastDataTransfer[i];
      numRead++; numRemaining--;
    }
    
    moreToRead = numRead < intoArraySize;
    
    if (firstIteration) {  //if it is the first iteration, note that we're done with it
      report(1);    //report status so computer knows to send next set
      firstIteration = 0;   
    }
  } while (moreToRead);    
}

//sends a set of floats all at once (no feedback from receiving computer)
FASTRUN void sendFloats(float sendArray[], unsigned int sendArraySize, bool clampDuring) {

  if (clampDuring) {
    for (size_t i = 0; i < sendArraySize; i++) { sendFloat(sendArray[i]); clampStep(); }
  } else {
    for (size_t i = 0; i < sendArraySize; i++) { sendFloat(sendArray[i]); }
  }
}

//Read float values into cp.lastDataTransfer
//reportType options match report:
//0  -- no reply (usually the calling function will be replying at a later time)
//1  -- standard status plus all parameters (see report)
//-1 -- time out error plus all parameters
//2  -- echo back last received serial input
FASTRUN void readFloats(int reportType) {
  //read last serial
  for (size_t i = 0;i<floatsPerStandardDataTransfer;i++){
    cp.lastDataTransfer[i] = readFloat();   //readFloat will return nan in case of unexpectedly out of data to read
    clampStep();  //tradeoff here: getting faster clamp during serial i/o, but slower serial i/o by ~3 micros * 16 = ~50 micros
  }  

  //tried only this instead of clampStep() in loop, and it was not good enough to increase clamp speed during serial i/o
  //the 16 reads are the bottle neck
  //clampStep();
  report(reportType);
}

//standard response is to report back what was received (as 32-bit floats, hopefully)
//see readFloats() for a description of reportType options
FASTRUN void report(int reportType) {   //1 for standard report, which indicates expected behavior. 0 for bug report, which indicates a time out

  //handle no reporting (0)
  if (reportType == 0) {
    return;
  }  

  //handle echo back (2)
  if (reportType == 2) {    //echo back
    for (size_t i = 0 ; i < floatsPerStandardDataTransfer; i++) {
      sendFloat(cp.lastDataTransfer[i]);
    }
    Serial.send_now();  
    return;
  }

  //1 or -1 both send a status float (1 or -1) followed by all parameters
  sendFloat(aec.electrodeKernelReceived && sp.historyWrapped);//sendFloat(reportType);
  //send status data, positions 1-12
  sendFloat(sp.lastReadMillis); //1st value
  sendFloat(sp.lastVm); //2
  sendFloat(sp.lastVmPinReading); //3
  sendFloat(sp.lastArbitraryMultiplier); //4
  sendFloat(sp.conductanceMultiplier12bit); //5
  sendFloat(sp.lastLeakCurrent); //6
  sendFloat(sp.lastArbitraryCurrent_scaled); //7
  sendFloat(sp.lastTotalCurrent); //8
  sendFloat(aec.lastConvolutionResult); //9
  sendFloat(rs_mean()); //10
  sendFloat(rs_variance()); //11
  sendFloat(rs_minVal()); //12
  sendFloat(rs_maxVal()); //13
  sendFloat(sp.calibrationDataReceived); //14//sendFloat(sp.calibrationDataReceivedCount); //14
  int historyPos;
  if (sp.historyPos < 1) {
    historyPos = memLengthPnts - 1;
  } else {
    historyPos = sp.historyPos-1;
  }
  sendFloat(sp.dts[historyPos]);
  //sendFloat(getAecStatus()); //15 -- one for running, zero for not. combine this with sendFloat as a bit-wise
  
  Serial.send_now();  
}

//byte to float and float to byte for serial i/o... proably a built in function for this...
union {   //set 4 bytes or a float and use other to read out as the a float or 4 bytes, respectively
  byte asByte[4];
  float asFloat;
} data;

//send a float over serial i/o (has to go a byte at a time)
FASTRUN void sendFloat(float toSend) {
  data.asFloat = toSend;
  
  for (size_t i=0;i<4;i++) {
    Serial.write(data.asByte[i]);
  }
}

//read a float value from Serial I/O
FASTRUN float readFloat() {
  if (Serial.available() < 4) {   //can only read for bytes at a time
    return nanVal;  //not sure how to return nan
  }

  for (size_t i=0; i<4; i++) data.asByte[i] = Serial.read();    //read bytes
  return data.asFloat;   //return the float representation
}

