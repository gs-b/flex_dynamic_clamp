# flex_dynamic_clamp
A flexible, affordable dynamic clamp. It is based on an economical and programmable [microprocessor](https://www.pjrc.com/store/teensy36.html). It extends the designs of [Niraj Desai and colleagues](http://dynamicclamp.com/) by allowing arbitrary conductance waveforms and current-voltage relations, [Active Electrode Compensation (AEC)](https://www.sciencedirect.com/science/article/pii/S0896627308005394), and automatic calibration.

<img align="center" src="https://raw.githubusercontent.com/gs-b/flex_dynamic_clamp/master/img/guiImage.png" width="300">

Dynamic clamp devices mimic the addition (or subtraction) of transmembrane conductances in live cells during whole-cell patch clamp electrophysiology experiments. This dynamic clamp is inspired by the [paper](http://www.eneuro.org/content/4/5/ENEURO.0250-17.2017) and [designs](http://dynamicclamp.com/) of Niraj Desai, Richard Gray, and Daniel Johnston. This version of the dynamic clamp can easily be implemented on circuits built to Desai et al.'s design specifications. This version adds:

<ins>Arbitrary conductance waveforms</ins>

In parallel with reading the membrane voltage for the real-time dynamic clamp calculation, flex_dynamic_clamp programs the microprocessor to modulate a conductance based on a 0-3.3V input pin. Any digital-to-analog converter (DAC) can be used to generate this signal, including DACs common in cellular electrophysiology (e.g., Molecular Devices Digidata boards and NIDAQ boards). In testing, the dynamic clamp follows this commmand in time steps as small as 2.5 microseconds (closer to 8 microseconds with AEC)

<ins>Arbitrary current-voltage relations</ins>

The relationship between voltage and current for the commanded conductane can be programmed to have any shape (see for example the wave-like pattern in the GUI image above). This is useful when modeling an unusual (e.g., non-ohmic) current-voltage relation. 

<ins>Active electrode compensation</ins>

[AEC](https://www.sciencedirect.com/science/article/pii/S0896627308005394) is implemented in real-time by 1) delivering a noise stimulus to a cell during a recording, 2) computing the (linear) kernel representing the relationship of injected current (injected through the pipette) and membrane voltage, 3) decomposing the kernel into compenents due to voltage drop across the electrode and that across the cell, 4) using the electrode component to generate a prediction for the measured voltage drop attributable to the electrode during the recording, and 5) subtracting that prediction from the measured membrane voltage in real-time to obtain a more faithful representation of the membrane voltage. 

<img src="https://raw.githubusercontent.com/gs-b/flex_dynamic_clamp/master/img/kernelAndComponentsExample.png" width="300"><img src="https://raw.githubusercontent.com/gs-b/flex_dynamic_clamp/master/img/stepExample.png" width="300">


<ins>Automatic calibration</ins>

For accuracy, the electrical circuitry has to be calibrated. flex_dynamic_clamp implements routines to perform calibration and generate plots like those below in seconds. Note that auotmatic calibration with flex_dynamic_clamp currently requires [Igor NIDAQ Tools MX](https://www.wavemetrics.com/products/nidaqtools).

<img src="https://raw.githubusercontent.com/gs-b/flex_dynamic_clamp/master/img/inputCalibrationEx.png" width="450"><img src="https://raw.githubusercontent.com/gs-b/flex_dynamic_clamp/master/img/outputCalibrationEx.png" width="450">
