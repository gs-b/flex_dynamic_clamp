// Automatic calibration run over serial input/output

#include <ADC.h>
#include <array>

// three calibration actions:
// input-side calibration: just returns a set of readings (length inputSideCalReads) over serial output to computer
// follow (intended mainly for response time quantification) 

// input-side calibration: read 16 vm values (length of one standard data transfer) and return over serial
FASTRUN void sendInputCalibrationReads() { 
    for (size_t i = 0 ; i < floatsPerStandardDataTransfer; i++) {
      sendFloat(adc->adc0->analogReadContinuous());
    }
    Serial.send_now(); 
}

// output-side calibration: command value betweeb 0-4095 
//send an nan, followed by 1 if wrote and zero if not wrote (because input out of range), followed by echo back, followed by nans
FASTRUN void writeForOutputCalibration() {
  if ( (cp.lastDataTransfer[3] >= 0.0) && (cp.lastDataTransfer[3] <= 4095.0) ) {
    analogWrite(A21,(int)cp.lastDataTransfer[3]);
    sendFloat(nanVal);
    sendFloat(1.0);
  } else {
    sendFloat(nanVal);
    sendFloat(0.0);
  }
  sendFloat(cp.lastDataTransfer[3]);
  sendFloat((float)dac_pin0);
  for (size_t i = 4; i < floatsPerStandardDataTransfer; i++) { sendFloat(nanVal); }
  Serial.send_now(); 
}

//Start follow mode (with cp.lastDataTransfer[3]  == 1) or stop it with anything outside the exclusive range 0 to 2
//)in fact, follow mode is broken upon any other serial input)
FASTRUN void setFollowModeForCalibration() {
  if ( (cp.lastDataTransfer[3] > 0) && (cp.lastDataTransfer[3] < 2) ) { followFast(); }
}

FASTRUN void followFast() {
  analogWrite(dac_pin0,constrain(adc->adc0->analogReadContinuous(),0,4095));    //writes value to pin (no echoing to serial)
  if (Serial.available() > 0) { return; }
}

