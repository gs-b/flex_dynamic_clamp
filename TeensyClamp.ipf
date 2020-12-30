#pragma TextEncoding = "UTF-8"
#pragma rtGlobals=3		// Use modern global access method and strict wave access.
#pragma IndependentModule = TeensyClamp // independent module, continues running even if code outside the module is uncompiled

// Load NIDAQmx procedures (needed for autocalibration, if available)
#if (exists("NIDAQmxWaveScanProcs"))	
#include <NIDAQmxWaveScanProcs>				//Igor NIDAQ Tools MX required procedures
#endif

#if (exists("NIDAQmxWaveScanProcs"))	
#include <NIDAQmxWaveFormGenProcs>
#endif

//---Teensy dynamic clamp--- see https://github.com/gs-b/flex_dynamic_clamp

//requires Igor NIDAX tools mx and #include procs associated with it (to apply voltage commands and read voltage output) (Uses Scan Control & Waveform Generator)
//requires VDT2 (to tell the teensy what to do)
//The sketch TeensyClamp.ino must be loaded onto the Teensy

//the following connections must be made from the Teensy to the scaling circuitry and NIDAQ board:
//(TODO enter these)

//Overview of input-side calibration:
//input to Teensy commands from +/-10V, record command, scaled command, and teensy readings, fit these to get input-relation (stored in the Package folder)
	
//Overview of output-side calibration:
//command Teensy to output 0-3.3V, record teensy output, scaled output, fit these to get output-relation (stored in the Package folder)


//use may need to modify:
static strconstant ks_dacName = "dac0"																//name of DAC is Igor NIDAQ tools
strconstant ks_teensyCom = "COM21"																		//this is a default that can be changed so that you don't have to enter the port name each time. User is prompted un start up
static strconstant ks_internalSolutions = "Kmes;CsCl;D-Mann;NMDG-Asp;TEA-Phos;"		//optionally list junction potentials in order to set them easily in the GUI (they can also be entered manually)
static strconstant ks_junctionPotentialPresets = "-8.43;-4.43;-7.43;-3.74;-5.71;"	//the junction potential associated with

//user may also need to modify, and these must also match on the teensy
constant input_amplifier_mV_per_membrane_mV = 50				// scale factor for amplifier mV per membrane mV (listed in parenthesis after Primary Output in multiclamp commander I-clamp tabs. For gain of 5 on 700B, it's 50 mV/mV
																				//NOTE: input_membrane_mV_per_amplifier_V = 1000/input_amplifier_mV_per_membrane_mV		//easier to invert and convert to mV membrane potential per V amplifier change since we can read that in raw volts
constant output_injected_pA_per_commanded_V	= 400			//scale factor for current injected in pA per volt to amplifier (in multiclamp commander under options (F10), gains tab, external command sensitivity)

//input-side pins
static constant k_teensyCmdChanNum = 0 				//on NIDAQ, # of analog in pin (as in AI#). I use analog out (AO) 0, which has chanNum = 0
static constant k_teensyCmdCopyChanNum	= 0		//copy of command is recorded by what analog in (AI) pin
static constant k_teensyInputCopyChanNum = 1		//copy of scaled input to teensy is recorded by what analog in (AI) pin

//output-side pins
static constant k_teensyOutputCopyChanNum = 2				//copy of teensy DAC output (unscaled, 0-3.3V range)
static constant k_teensyScaledOutputCopyChanNum = 3 	//scaled teensy output (scaled, +/-10V range)

//user will not need to modify, but might want to
constant k_comBaud = 115200
static constant k_byteLimit = 64 								//empirical testing shows that only 64 bytes (16 32-bit float-point values) can be sent over the serial I/O at a time
static constant k_floatsPerStandardDataTransfer = 16	//should match in ino sketch.. GUI will update teensy by sending this many floats, where the order specifies what is what. Assumed to be maximum sendable
static constant k_teensyStateBufferSize = 10000			//wave will store this number of samples of teensy responses, including cell Vm, comand,etc. k_numStatusPoints sets how many items are stored here (wave is rows k_teensyStateBufferSize cols k_numStatusPoints)

//---with luck, users will never have to touch the code below this point!---

//This defines a menu item and hotkey to start a TeensyClamp GUI
Menu "Macros"
	"Start TeensyClamp GUI/1",startGUI("")
end


//Function called to start a new GUI to a control a teensy (in future: add macro with hotkey)
//functions here continue to take a comStr argument instead of using ks_teensyCom in case of multiple teensy devices (not tested)
function startGUI(comStr)
	String comStr		//allows multiple windows for multiple teensy clamps, though one is generally anticipated and has been tested
	
	if (strlen(comStr) < 1) //let user choose default or other through a dialog
		comStr = ks_teensyCom
		prompt comStr,"Specify Com Port for Teensy Dynamic Clamp"
		String helpStr = "The Teensy must be accessible to Igor as a Serial Port. To find available ports, run \"VDTGetPortList2;print s_vdt\. The default port, "+ks_teensyCom+", can be changed in TeensyClamp.ipf"
		doprompt/help=helpStr "Teensy Com Port?", comStr
	endif
	
	//panel specifications  -- first name panel and create Packages folder if it doesnt exist (same folder is used by teensyCal_inputCal() and teensyCal_outputcal() to store calibration data
	String panelN = "teensy_clamp_" + comStr
	String folderPath = "root:Packages:"+panelN
	NewDataFolder/o root:Packages
	newDataFolder/o $folderPath
	Variable panelHeight =4.5*72,panelWidth=3*72
	Variable fontSize=11
	
	//slider specifications -- each slider 
	Variable sliderWidth=72,sliderHeight=6,sliderSetVertGap=50,sliderSetVarSpacing=2,sliderRightSpacing=6
	Variable setVarWidth=72,setVarHeight=12
	String sliders="dc_pA;leak_nS;leak_mV;"
	String sliderHelps="Set DC (steady) current offset in pA (0 disables it);Set leak conductance in nS (0 disables it);Set leak reversal potential in mV;"
	String sliderLowLimits = "-100;-2;-100;"
	String sliderHighLimits = "100;10;100;"
	String sliderIncrements = "5;1;5;"
	String sliderDefaultVals = "0;0;0;"
	String setVarTitles = "pA;nS;mV;"
	String slider_svAppndStr = "ssv"		//cannot contain an underscore! short for slider set var, cannot be used as ending for other set variabes that call the same proc.
	String includeSetVarDataInSettings = "1;1;1;"		//whether to send set var data to teensy, likely yes for all	
	
	//checkbox specificatipons
	Variable cbHeight=14,cbWidth=150,cbVertSpacing=0,cbRows=3
	String checkboxes="running;leakClamping;arbClamping;liveUpdating;runAec;"			//in future, might be good to append something like CB to avoid name conflicts
	String cbTitles="Running;Leak clamp;Arb. clamp;Auto;AEC;"
	String cbHelpStrs="Run clamp (zero current output if no other buttons clicked -- cannot be running during calibration!;"
	cbHelpStrs+="Run leak clamp (simulate a leak conductance based on nS, mV to the left;"
	cbHelpStrs+="Initiate arbitrary (arb.) clamp;"
	cbHelpStrs+="Send changes to GUI immediately (automatically). SHIFT click when unchecked to send a single update for all;"
	cbHelpStrs+="Use AEC (Active Electrode Compensation). Requires a calculated and sent electrode kernel. SHIFT click to calculate. CTRL+SHIFT click to send to teensy;"
	String includeCbInSettings = "1;1;1;0;1;"		//whether to send checkbox data to teensy, likely only arbitrary clamp
	
	//data folder (currently  stores iv relation, calibration data, and teensy status history wave) -- a design goal was to avoid global variables, but these are unavoidable
	//currently won't be killed with window. Could add a window hook to do so, but would probably want to prompt user in case they want to keep the I(V) waves
		//iv relations
	make/o/d/n=(4096) $(folderPath+":ivRel_lastSent") = nan,$(folderPath+":ivRel_toSend") = p-4096/2,$(folderPath+":leakRel") = nan,$(folderPath+":totalRel") = nan		//just some arbirary ivRel_toSend, user should alter 
	WAVE ivRel_toSend = $(folderPath+":ivRel_toSend"),ivRel_lastSent=$(folderPath+":ivRel_lastSent")
	WAVE leakRel = $(folderPath+":leakRel"),totalRel = $(folderPath+":totalRel")
	make/o/wave/free toScaleWvs = {ivRel_toSend,ivRel_lastSent,leakRel,totalRel}
	//must call teensy_gui_scaleIvs(toScaleWvs,panelN) after panel is built to finish makin these iv waves
	
	//also create a wave to store teensy responses that come in over usb serial
	make/o/d/n=(k_floatsPerStandardDataTransfer) $(folderPath+":lastTeensyResponse") = -inf	//dont initialize to nan because all nan signals a type of teensy error (time out during iv)
	
	//Build panel
	NewPanel/K=1/N=$panelN/W=(0,0,panelWidth,panelHeight)
	Setwindow $PanelN,userdata(folderPath)=folderPath
	Setwindow $panelN,userdata(comStr)=comStr,hook(teensy_gui_killed_hook)=teensy_gui_killed_hook
	SetWindow $panelN,userdata(numItemsReturnedByTeensy)="0"		//will be a counter of how many messages have been received from teensy
	
	teensy_gui_scaleIvs(toScaleWvs,panelN)
	
	//add sliders (and check boxes)
	int i, num = itemsinlist(sliders)
	Variable currLeft=0,currTop=0
	String name,help,svName
	setwindow $panelN,userdata(svsToSend)=""		//tracks what set vars will be sent to teensy, filled in in loop below
	for (i=0;i<num;i++)
		name = stringfromlist(i,sliders)
		svName = name+"_"+slider_svAppndStr
		if (stringmatch(stringfromlist(i,includeSetVarDataInSettings),"1"))
			setwindow $panelN,userdata(svsToSend)+=svName+";"
		endif
		
		//slider (actually drawn below)
		Slider $name win=$panelN,pos={currLeft,currTop+setVarHeight+sliderSetVarSpacing},size={sliderWidth,sliderHeight},proc=teensy_gui_sliderHandling,fsize=fontSize,userdata(svName)=svName,ticks=3
		Slider $name vert=0,limits={str2num(stringfromlist(i,sliderLowLimits)),str2num(stringfromlist(i,sliderHighLimits)),str2num(stringfromlist(i,sliderIncrements))},value=str2num(stringfromlist(i,sliderDefaultVals))
		
		//set variable (drawn above)
		setvariable $svName win=$panelN,pos={currLeft,currTop},size={setVarWidth,setVarHeight},fsize=fontSize,proc=teensy_gui_svHandling
		setvariable $svName limits={str2num(stringfromlist(i,sliderLowLimits)),str2num(stringfromlist(i,sliderHighLimits)),str2num(stringfromlist(i,sliderIncrements))},value=_NUM:str2num(stringfromlist(i,sliderDefaultVals))
		setvariable $svName title=stringfromlist(i,setVarTitles),userdata(sliderName)=name
		
		currTop += setVarHeight+sliderSetVarSpacing + sliderSetVertGap
	endfor
	
	//add status setvar
	setvariable $("portStatusSetVar_"+panelN) win=$panelN,pos={currLeft,currTop},size={135,12},fsize=fontSize,disable=2,title="Port",help={"Status of serial port i/o"},value=_STR:"Disconnected",proc=teensy_gui_svHandling
	
	//add junction potential setvar
	setvariable $("juncPotSetVar_"+panelN) win=$panelN,pos={currLeft+135+10,currTop},size={73,12},fsize=fontSize,title="JP",help={"Set the junction potential (used by the teensy to adjust the current output)\rValue is ADDED to the voltage reading to give the true voltage\rCLICK  on the \"JP\" label for preset options"},value=_NUM:str2num(ks_junctionPotentialPresets),proc=teensy_gui_svHandling
	setwindow $panelN,userdata(svsToSend)+="juncPotSetVar_"+panelN+";"
	currTop+=setVarHeight+4
	
	//add (error) message board
	popupmenu $("messagePopup_"+panelN) win=$panelN,pos={currLeft,currTop},size={500,12},mode=1,value="Message history: no messages;",noproc,userdata(emphasis)="0",title="Msgs"
	
	//add teensy status/state history plot. state history wave is a rolling index (but maybe so long will never hit end); 
	WAVE teensyStateHistory = teensy_gui_resetStateHistory(panelN)	
	currTop += 20
	String graphN = panelN+"_statusDisp"
	setwindow $panelN,userdata(graphN)=graphN
	display/host=$panelN/w=(currLeft,currTop,currLeft+panelWidth,currTop+250)/n=$graphN teensyStateHistory[][%lastVm]/tn=lastVm vs teensyStateHistory[][%lastReadSecs]
	appendtograph/W=$(panelN+"#"+graphN)/r teensyStateHistory[][%lastTotalCurrent]/tn=lastTotalCurrent vs teensyStateHistory[][%lastReadSecs]
	modifygraph/w=$(panelN+"#"+graphN) rgb(lastTotalCurrent)=(0,0,0)
	Label/W=$(panelN+"#"+graphN) bottom,"Read time (from connection start, s \\E)"
	Label/W=$(panelN+"#"+graphN) left,"mV\\u#2"
	Label/W=$(panelN+"#"+graphN) right,"pA\\u#2"
	setaxis/A=2 left; setaxis/A=2 right;
	
	//add checkboes, then one setvar for I(V) multiplier
	num = itemsinlist(checkboxes)
	int currRow,currCol
	Variable cbLeft,cbCols = floor((num-1)/cbRows) + 1
	currLeft = sliderWidth + sliderRightSpacing
	setwindow $panelN,userdata(cbsToSend)=""		//tracks what cbs will be sent to teensy, filled in in loop below
	
	variable endnum = num+1
	for (i=0;i<endnum;i++)		//currently 5, want to calculate position for a 6th item, the setvar
		currRow = mod(i,cbRows)
		currCol = floor(i/cbRows)
		currTop = (cbHeight + cbVertSpacing)*currRow
		cbLeft = currLeft + currCol*cbWidth/cbCols
		if (i >=num)
			break
		endif
		name = stringfromlist(i,checkboxes)
		help = stringfromlist(i,cbHelpStrs)
		if (stringmatch(stringfromlist(i,includeCbInSettings),"1"))
			setwindow $panelN,userdata(cbsToSend)+=name+";"
		endif
		
		Checkbox $name win=$panelN,pos={cbLeft,currTop},size={cbWidth/cbCols,cbHeight},fsize=fontSize,proc=teensy_gui_cbHandling,title=stringfromlist(i,cbTitles),help={stringfromlist(i,cbHelpStrs)}
		
	endfor
	
	//add the set var in last cb position -- this setvar doesnt get handled like others bc no associated slider
	String ivMultSetVarName = "ivMultiplierSetVar_"+panelN
	setvariable $ivMultSetVarName  win=$panelN,pos={cbLeft,currTop},size={cbWidth/cbCols,cbHeight},fsize=fontSize,proc=teensy_gui_svHandling 
	setvariable $ivMultSetVarName value=_NUM:1,title="I(V)*=",help={"Multiply I(V) relation by value -- 1.0 for no multiplier. NOTE: NOT REFLECTED IN DISPLAY!!!"}
	setwindow $panelN,userdata(svsToSend)+=ivMultSetVarName+";"
	
	currTop = (cbHeight + cbVertSpacing)*cbRows
	
	//add calibration popup menu and I(V) relation popup menu
	currtop += 1
	Button autoCalibrate win=$panelN,pos={currLeft,currTop},size={cbWidth/2-4,cbHeight+2},fsize=fontSize,proc=teensy_gui_btnHandling,title="Calibrate",help={"Automatic Teensy Calibration"}
	Button sendIvRel win=$panelN,pos={currLeft+cbWidth/2-3,currTop},size={cbWidth/2-4,cbHeight+2},fsize=fontSize,proc=teensy_gui_btnHandling,title="Send I(V)",help={"Send I(V) relation in red below for use arbitrary clamp I(V)"}
	
	//add I(V) graph
	currtop+=19
	graphN=panelN+"_ivDisp"
	display/host=$panelN/w=(currLeft,currTop,currLeft+cbWidth,currTop+cbWidth*0.8)/n=$graphN ivRel_lastSent/tn=lastSent,ivRel_toSend/tn=toSend,leakRel/tn=leakRel,totalRel/tn=totalRel
	modifygraph/w=$(panelN+"#"+graphN) rgb(lastSent)=(0,0,0),lsize(lastSent)=2
	
	currTop += cbWidth
	
	//connect to port, set status as not waiting for response
	teensy_gui_setConnection(panelN,1)
	teensy_gui_setResponseWaitStatus(panelN,0)		//since it's disconnected, the status will be set to not waiting
	
	doupdate;print "teensy_clamp() connecting and sending calibration data... (successful connection and calibration will be confirmed momentarily; or issues will be reported)"
	setwindow $panelN userdata(teensyCalibrationConfirmed)="0"		//used in teensy_gui_updateFromTeensyResponse to track whether teensy calibration has been confirmed, so we dont have to do it more than once
	teensy_gui_sendCalibration(panelN,1)
end

function teensy_gui_killed_hook(s)
	STRUCT WMWinHookStruct &s
	
	if (s.eventCode != 2)		//ignore all but window killed
		return 0
	endif
	
	//try to turn off the running flag so teensy isn't doing anything while disconnected and also can be calibrated with GUI off
	Checkbox running win=$s.winname,value=0
	teensy_gui_sendSettings(s.winname,1,noReceiveBg=1)
	
	//close the com port
	String comStr = getUserData(s.winName,"","comStr")
	vdtcloseport2 $comStr
	
	//kill the background tasks
	String taskName = ks_teensyFloatsRespBgTaskStartStr+s.winName//"sendIvBgTask_"+s.winName	//"sendIvBgTask_"+s.winName
	String bgTasks = background_getTaskList()	//this function checks indirectly, quererying CtrlNamedBackground_all_, This is good because checking directly actually CREATES the task
	if (whichlistitem(taskName,bgTasks) >= 0)		//task not yet created
		CtrlNamedBackground $taskName,kill=1
	endif
	taskName = ks_teensyFloatRespBgTaskStartStr+s.winName
	if (whichlistitem(taskName,bgTasks) >= 0)		//task not yet created
		CtrlNamedBackground $taskName,kill=1
	endif
end

function teensy_gui_sliderHandling(s) : SetVariableControl
	STRUCT WMSliderAction &s
	
	//print s.eventcode
	
	//respond to many events to ensure set var matches, but we'll only send settings for mouse upp		//respond to only: val set by mouse down (3) or by dragging/arrow) considered also:,mouse up,
	if ((s.eventCode != 3) &&  (s.eventCode != 9) && (s.eventCode != 4) && (s.eventCode != 8))
		return 0
	endif
	
	String svName = getuserdata(s.win,s.ctrlName,"svName")		//we'll always store most up-to-date value in svName
	ControlInfo/w=$s.win $svName
	Variable lastVal = V_Value
	
	Variable currVal = s.curval
	
	if (currVal != lastVal)
		setvariable $svName value=_NUM:currVal		//update set variable
	endif
		
	if (s.eventCode == 4)	//only send settings for mouse up
		teensy_gui_sendSettings(s.win,0)						//update teensy if liveUpdating
	endif
	
	
end

function teensy_gui_svHandling(s) : SetVariableControl
	STRUCT WMSetVariableAction &s
	//mainly respond to only: mouse up, enter, mouse scroll wheel up, mouse scroll wheel down, end edit -- responding to enter appears redundent with end edit and results in double calls
	//also responds to mouse down in LABEL area, clicking allows range to change
	String sliderName
	int clickInLabelArea = (s.eventCode == 9) && (s.mousePart == 0)
	
	//handle set vars associated with a slider
	if (stringmatch(s.ctrlName,"*_ssv"))	
		//handle changes to range via click in label area	
		if (clickInLabelArea)
			ControlInfo/w=$s.win $s.ctrlname
			String startStr = stringbykey("limits",s_recreation,"=",",")
			int startInd = strsearch(s_recreation,startStr,0,2^2)
			int endInd = strsearch(s_recreation,"}",startInd,2^2)
			String pre = replacestring("{",s_recreation[startInd,endInd],"")
			pre = replacestring("}",pre,"")
			Variable range_min=str2num(stringfromlist(0,pre,",")),range_max=str2num(stringfromlist(1,pre,",")),step_size=str2num(stringfromlist(2,pre,","))
			prompt range_min, "Range min"
			prompt range_max,"Range max"
			prompt step_size,"step size"
			doprompt "Change range and step size for slider",range_min,range_max,step_size
			if (V_flag)		//cancel
				return 0
			endif
			sliderName = getuserdata(s.win,s.ctrlname,"sliderName")
			setvariable $s.ctrlname win=$s.win,limits={range_min,range_max,step_size}
			Slider $sliderName win=$s.win,limits={range_min,range_max,step_size}
			return 0
		endif
		
		if ((s.eventCode != 1) && (s.eventCode != 4) && (s.eventCode != 5) && (s.eventCode != 8))	//ignore non-edits
			return 0
		endif
		
		sliderName = getuserdata(s.win,s.ctrlName,"sliderName")
		Slider $sliderName value=s.dval		//update slider
		teensy_gui_sendSettings(s.win,0)				//update teensy if liveUpdating
		
	//handle set var associated with the junction potential -- allow user to choose from presets if clicked on title
	elseif (stringmatch(s.ctrlname,"juncPotSetVar_"+s.win))		//set var associated with junction potential
		if (clickInLabelArea)		//ks_internalSolutions ks_junctionPotentialPresets
			String promptStr="";int i,numInternals=itemsinlist(ks_junctionPotentialPresets)
			for (i=0;i<numInternals;i++)
				promptStr+=stringfromlist(i,ks_internalSolutions)+" ("+stringfromlist(i,ks_junctionPotentialPresets)+");"
			endfor
			Variable internalNum = 0
			Prompt internalNum, "Select internal -- or exit and type directly into the field. (Change these presents by editing: ks_internalSolutions & ks_junctionPotentialPresets)", popup promptStr
			doprompt "Select internal - junction potential pair",internalNum
			if (!V_flag)		//not cancelled
				setvariable $("juncPotSetVar_"+s.win),value=_NUM:str2num(stringfromlist(internalNum-1,ks_junctionPotentialPresets))		//internalNum starts at one for prompt for some reason
			endif
		elseif ((s.eventCode != 1) && (s.eventCode != 4) && (s.eventCode != 5) && (s.eventCode != 8))
			return 0		//ignore non-edits by returning because we will react to this as a change in settings
		endif
		
		teensy_gui_sendSettings(s.win,0)
		
	//port status set var, respond if status is "unavailable"
	elseif (stringmatch(s.ctrlName,"portStatusSetVar_"+s.win))		
		if (s.eventCode == 1) 		//mouse up
			Variable closeOpenOrCheck = 1	//default move is to open
			prompt closeOpenOrCheck ,"Close (0), Open (1), check (2), or reset (3) port?" 	//default move is to open
			doprompt "Port status change",closeOpenOrCheck 
			if (closeOpenOrCheck > 2)		//try a reset
				teensy_gui_postMessage(s.win,"PORT: Attempting port reset (warning: other ports will be disconnected)",0)
				vdt2 resetPorts
				teensy_gui_setConnection(s.win,1)
			else
				teensy_gui_setConnection(s.win,closeOpenOrCheck)
			endif
		endif
	
	elseif (stringmatch(s.ctrlname,"ivMultiplierSetVar_"+s.win))
		if (s.eventCode == 1) 		//mouse up
			teensy_gui_sendSettings(s.win,0)		//just send settings if in live mode
		endif
	endif
end

function teensy_gui_cbHandling(s) : CheckBoxControl
	STRUCT WMCheckboxAction &s
	
	if (s.eventCode != 2)		//respond only to mouse up
		return 0
	endif
	
	strswitch (s.ctrlName)
		case "liveUpdating":
		
		//check for live updates
		if (s.eventMod & 2^1)		//if shift click, send data now. Also revert inveitable switch in "checked" status.
			checkbox liveUpdating win=$s.win,value=!s.checked						//undo whatever this click did
			teensy_gui_postMessage(s.win,"Live updates: settings sent to Teensy (still not live-updating -- check box w/o shift to start",0)
			teensy_gui_sendSettings(s.win,1)			//send settings to the teensy
		endif
		
			//continue to arb clamping
			
		case "running":	
			//continue to arb clamping	
			
		case "leakClamping":		//connect or disconnect
			//continue to arb clamping
			
		case "runAec":
			//continue to arb clamping	
			
		case "arbClamping":		//toggle arbitrary clamp
			teensy_gui_sendSettings(s.win,0)		//update teensy if liveUpdating
			break
	endswitch
end

static constant k_default_inputCal_slope = 7.8236
static constant k_default_inputcal_offset = 2452.6
static constant k_default_outputCal_slope = -0.6856629814566838
static constant k_default_outputCal_offset = 1330.077908723307
function teensy_gui_scaleIvs(wvRefWv,panelN)
	String panelN
	WAVE/WAVE wvRefWv

	String folderPath = getUserdata(panelN,"","folderPath")
	WAVE/Z calibrationWv = $(folderPath+":calibrationWv"); int lastCol=dimsize(calibrationWv,1)-1
	Double inputCal_slope = Waveexists(calibrationWv) ? calibrationWv[%inputCal_slope][lastCol] : k_default_inputCal_slope

	int i,num= dimsize(wvRefWv,0) 
	for (i=0;i<num;i++)
		WAVE curr = wvRefWv[i]
		setscale/p x,teensy_gui_bit2vmOrVm2bit(panelN,0,0),1/inputCal_slope,"mV",curr
					//setscale/p x,(0 - inputcal_offset)/inputCal_slope,1/inputCal_slope,"mV",curr	//vals from calibration  "convert from teensy reads with: (Mem voltage)=((teensyRead)-(offset))/(slope); (Mem voltage)=((teensyRead)-(2452.6))/(7.8236)"
		setscale d,-1,1,"pA",curr
	endfor
end

//converts from 12bit reading to Vm in mV via (Mem voltage)=((teensyRead)-(offset))/(slope); e.g., (Mem voltage)=((teensyRead)-(2452.6))/(7.8236)"
//or for vm2bit == 1: converts from vm to 12 bit readingOrVm
function teensy_gui_bit2vmOrVm2bit(panelN,readingOrVm,vm2bit)
	String panelN;int readingOrVm;int vm2bit		//pass 1 to get vm2bit instead of bit reading to vm 
		
	String folderPath = getUserdata(panelN,"","folderPath")
	WAVE/Z calibrationWv = $(folderPath+":calibrationWv"); int lastCol=dimsize(calibrationWv,1)-1
	Double inputCal_slope,inputcal_offset
	if (Waveexists(calibrationWv))
		inputCal_slope = calibrationWv[%inputCal_slope][lastCol]
		inputcal_offset = calibrationWv[%inputcal_offset][lastCol]
	else
		inputCal_slope = k_default_inputCal_slope
		inputcal_offset = k_default_inputcal_offset
	endif	
	
	if (vm2bit != 1)
		return (readingOrVm - inputcal_offset) / inputCal_slope
	endif
	
	//vm2vit
	return (readingOrVm * inputCal_slope) + 	inputcal_offset
end

//converts from current to 12bitCmd with (teensyWriteVal)=((currentVal in pA)-(offset))/(slope); (teensyWriteVal)=((currentVal in pA)-(offset))/(slope)
function teensy_gui_current2bitOrBit2Current(panelN,currentOrWriteVal,writeVal2current)
	String panelN;int currentOrWriteVal;int writeVal2current		//pass 1 to get writeVal2current instead of current to writeVal (12 bit value)
	
	String folderPath = getUserdata(panelN,"","folderPath")
	WAVE/Z calibrationWv = $(folderPath+":calibrationWv"); int lastCol=dimsize(calibrationWv,1)-1
	Double outputCal_slope,outputcal_offset
	if (Waveexists(calibrationWv))
		outputCal_slope = calibrationWv[%outputCal_slope][lastCol]
		outputcal_offset = calibrationWv[%outputcal_offset][lastCol]
	else
		outputCal_slope = k_default_outputCal_slope
		outputcal_offset = k_default_outputcal_offset
	endif	
	
	if (writeVal2current != 1)
		return (currentOrWriteVal - outputcal_offset) / k_default_outputCal_slope
	endif
	
	//vm2vit
	return (currentOrWriteVal * outputCal_slope) + 	outputcal_offset
end


//main update function -- sends settings to teensy and also updates GUI based on changes to settings
//return 0 if failed to start background function, 1 if started successfully
function teensy_gui_sendSettings(panelN,bypassNonLiveMode,[customSettingsWv,noReceiveBg])
	String panelN	//name of panel for which to send updates
	Variable bypassNonLiveMode		//if 0: updates are only sent to the teensy if Live updates checkbox is checked [standard use]. If 1: updates are sent to the teensy no matter the status [expected to be reserved for a shift click of that box]
	WAVE customSettingsWv	//bypass to send a custom settings wv. This is currently used for sending calibration data
	Variable noReceiveBg
	
	noReceiveBg = !ParamIsDefault(noReceiveBg) && noReceiveBg
	
	if (!bypassNonLiveMode)		//check live updates checkbox
		controlinfo/W=$panelN liveUpdating
		if (!V_value)
			return 0		
		endif
	endif
	
	if (PAramIsDefault(customSettingsWv))
		WAVE settingsWv = teensy_gui_getSettingsWv(panelN)
	else
		WAVE settingsWv = customSettingsWv
	endif
	teensy_gui_updateLeakRel(panelN)	
	
	return teensy_sendOneSetOfFloats(panelN,settingsWv,0,0,noReceiveBg=noReceiveBg)		//send if not busy and start polling for teensy response
end

//get a wave summarizing the status of GUI settings
function/WAVE teensy_gui_getSettingsWv(panelN)
	String panelN
	
	
	//iterate through cbsToSend (checkbox data to send) and svsToSend (setVar data to send)
	make/o/n=(k_floatsPerStandardDataTransfer)/free settingsWv = nan		//just a basic update, so it's crucial that the first position STAYS NaN, a real number would indicate I(V) data transfer
	String cbs = getuserdata(panelN,"","cbsToSend")
	String svs = getuserdata(panelN,"","svsToSend")
	String allControls = cbs + svs		//since both have value stored in v_value, can combine
	int num = itemsinlist(allControls)
	
	int i,index; String name
	for (i=0;i<num;i+=1)
		index = i + 1		//+1 because the 0th position is reserved for telling teensy what's coming (via nan value at present)
		if (index >= k_floatsPerStandardDataTransfer)
			teensy_gui_postMessage(panelN,"teensy_gui_getSettingsWv(): Unexpectedly sending too many settings to teensy! Beyond limit set by "+num2str(k_floatsPerStandardDataTransfer)+" not all will be sent",1)
			break
		endif
		
		name = stringfromlist(i,allControls)
		ControlInfo/w=$panelN $name
		settingsWv[index]=V_Value		//e.g., if checked it's a 1, for "Arbitrary Clamp" this will tell teensy to keep arbitrary clamp on
	endfor
	
	//so output to teensy is currently:
	//0: NaN
	//1: running (0 or 1)
	//2: leak clamp (0 or 1)
	//3: arbitrary clamp (0 or 1)
	//4: AEC clamp (0 or 1)  [end of variable length section that depends on number of checkbox values to send]
	//5: dc current (pA)
	//6: leak condutance (nS)
	//7: leak reversal potential (mV)
	//8: junction potential (mV)
	//9: iv multiplier (unitless)
	//10-15: NaN (available for additional parameters)

	return settingsWv
end

//update leak iv relation
function teensy_gui_updateLeakRel(panelN)	//should be called upon settings update or I(V) send
	String panelN
	
	// $(folderPath+":ivRel_lastSent") = nan,$(folderPath+":ivRel_toSend") = p-4096/2,$(folderPath+":leakRel") = nan,$(folderPath+":totalRel") = nan	
	String folderPath = getUserdata(panelN,"","folderPath")
	WAVE ivRel_lastSent = $(folderPath+":ivRel_lastSent"),leakRel = $(folderPath+":leakRel"), totalRel = $(folderPath+":totalRel")
	WAVE settingsWv = teensy_gui_getSettingsWv(panelN)
	int leakClamp =  settingsWv[1]
	int arbitClamp = settingsWv[2]
	if (leakClamp)
		leakRel = (x - settingsWv[5])*settingsWv[4] - settingsWv[3]		//subtract the dc, so dc is conventional "current injected", which is negative in whole cell
	else
		leakRel = 0
	endif
	
	if (arbitClamp)
		totalRel = leakRel + ivRel_lastSent
	else
		totalRel = leakRel
	endif
	doupdate;
end

//copy leak iv relation to arbitrary clamp iv relation
function teensy_gui_leakRelToArbitraryIv(panelN)
	String panelN
	
	if (strlen(panelN) < 1)
		panelN = winname(0,64)	//top panel
	endif

	String folderPath = getUserdata(panelN,"","folderPath")
	WAVE leakRel = $(folderPath+":leakRel")
	teensy_gui_setArbitraryIv(panelN,leakRel)
end

function teensy_gui_setArbitraryIv(panelN,newIvWv)
	String panelN
	WAVE newIvWv
	
	if (dimsize(newIvWv,0) != 4096)
		print "teensy_gui_setArbitraryIv() iv wave is expected to be 4096 points! Aborting"
		return 0
	endif
	
	if (strlen(panelN) < 1)
		panelN = winname(0,64)	//top panel
	endif
	
	String folderPath = getUserdata(panelN,"","folderPath")
	WAVE ivRel_toSend = $(folderPath+":ivRel_toSend")
	duplicate/o newIvWv,ivRel_toSend	
	
end
  
//labels as list for use when starting the wave (way back in teensy_clamp()) -- should agree with send order in report() in main ino sketch
static strconstant ks_teensyReportLbls="receiveStatus;lastReadMillis;lastVm;lastVmPinReading;lastArbitraryMultiplier;conductanceMultiplier12bit;lastLeakCurrent;lastArbitraryCurrent_scaled;lastTotalCurrent;lastConvolutionResult;dt_mean;dt_var;dt_min;dt_max;calibrationDataReceivedCount;lastDt;"
static strconstant ks_additionalStatusLbls="dt_sdev;lastReadSecs;"		//currently we just convert dt_variance to sdev and lastReadMillis to secs
static constant k_numAdditionalStatusLbls=2
static constant k_defaultSecsOnGraphAxis = 5
//actual update function
function teensy_gui_updateFromTeensyResponse(panelN)
	String panelN

	//update status/state history buffer
	String folderPath = getUserdata(panelN,"","folderPath")
	WAVE respWv = $(folderPath+":lastTeensyResponse")
	WAVE teensyStateHistory = $(folderPath+":teensyStateHistory")
	int stateBufferIndex = str2num(getuserdata(panelN,"","stateBufferIndex"))
	teensyStateHistory[stateBufferIndex][0,k_floatsPerStandardDataTransfer-1]=respWv[q]
	teensyStateHistory[stateBufferIndex][%dt_sdev]=sqrt(teensyStateHistory[stateBufferIndex][%dt_var])
	teensyStateHistory[stateBufferIndex][%lastReadSecs]=teensyStateHistory[stateBufferIndex][%lastReadMillis]/1000
	
	//confirm calibration status if not already
	if (stringmatch(getuserdata(panelN,"","teensyCalibrationConfirmed"),"0"))	//calibration is not confirmed, check if we can cinform it
		if (teensyStateHistory[stateBufferIndex][%calibrationDataReceivedCount] > 0) 
			print "teensy_gui_updateFromTeensyResponse() Calibration (and connection) successful!"
			setwindow $panelN, userdata(teensyCalibrationConfirmed)="1"
		else 
			teensy_gui_postMessage(panelN,"teensy_gui_updateFromTeensyResponse() teensy was not calibrated on connection! Could be a connection issue, try restarting? Is the port available?",1)
		endif
	endif
	
	//modify view window x axis
	if (teensyStateHistory[stateBufferIndex][%lastReadSecs] > k_defaultSecsOnGraphAxis)
		string graphN = getuserdata(panelN,"","graphN")
		setaxis/W=$(panelN+"#"+graphN) bottom,teensyStateHistory[stateBufferIndex][%lastReadSecs]-k_defaultSecsOnGraphAxis,teensyStateHistory[stateBufferIndex][%lastReadSecs]
	endif
	
	//iterate state buffer index
	stateBufferIndex=mod(stateBufferIndex+1,k_teensyStateBufferSize)
	String stateBufferIndexStr;sprintf stateBufferIndexStr,"%d",stateBufferIndex
	setwindow $panelN,userdata(stateBufferIndex)=stateBufferIndexStr
end

function/wave teensy_gui_resetStateHistory(panelN,[doDisp])
	String panelN
	int doDisp		//mostly for troubleshooting, display the status wave in a table
	
	if (strlen(panelN) < 1)
		panelN = winname(0,64)	//top panel
	endif
	
	String folderPath = getUserdata(panelN,"","folderPath")	
	make/o/d/n=(k_teensyStateBufferSize,k_floatsPerStandardDataTransfer+k_numAdditionalStatusLbls) $(folderPath+":teensyStateHistory") = nan
	WAVE teensyStateHistory=$(folderPath+":teensyStateHistory")
	dl_assignlblsfromlist(teensyStateHistory,1,0,ks_teensyReportLbls+ks_additionalStatusLbls,"",0)
	setwindow $panelN,userdata(stateBufferIndex)="0"		//start index at zero, index is iterated each teensy state reading with mod(index,k_teensyStateBufferSize)
	setscale d,-1,1,"mV",teensyStateHistory
	
	note/nocr/k teensyStateHistory, "stateBufferIndex:0;"
	
	if (!paramisdefault(doDisp) & doDisp)
		edit/k=1 teensyStateHistory.ld
	endif
	return teensyStateHistory
end


//returns 1 if connected, 0 otherwise
function teensy_gui_setConnection(panelN,closeOpenOrCheck)
	String panelN
	int closeOpenOrCheck		//0: close, 1: open, 2: check
	
	String comStr=getuserdata(panelN,"","comStr")
	
	if (closeOpenOrCheck > 0)
		vdtgetportlist2
		String currentlyAvailable = S_VDT
		if (whichlistitem(comStr,currentlyAvailable) >= 0)
			if (closeOpenOrCheck==1)
				vdtoperationsport2 $comStr;VDT2/P=$comStr baud=k_comBaud;
				vdtopenport2 $comStr
				setvariable $("portStatusSetVar_"+panelN) win=$panelN,value=_STR:"Ready";doupdate;
				return 1
			else		//greater than 1, so don't connect but let us know it's available
				setvariable $("portStatusSetVar_"+panelN) win=$panelN,value=_STR:"Avaibale (click here to connect!)";doupdate;
				return 0
			endif
		else
			vdtgetportlist2/scan
			String allAvailable = S_VDT
			if (whichlistitem(comStr,allAvailable) >= 0)	//available with a reset
				setvariable $("portStatusSetVar_"+panelN) win=$panelN,value=_STR:"Port reset needed (click here!)";doupdate;
				return 0
			else
				setvariable $("portStatusSetVar_"+panelN) win=$panelN,value=_STR:"Port UNAVAILABLE (click here to RESET after restoring)";doupdate;
				return 0
			endif
		endif
	else		//close port
		vdtcloseport2 $comStr
		setvariable $("portStatusSetVar_"+panelN) win=$panelN,value=_STR:"Port CLOSED (click here to re-open)";doupdate;	
		return 0
	endif
end

//returns 2 if busy, 1 if connected, 0 unconnected (likely an issue), -1 if closed (likely user set that way). with tryConnect, will try to reconnect if disconnected
function teensy_gui_getConnectionStatus(panelN,tryConnect)
	String panelN; Variable tryConnect		//try to reconect if it appears unavailable
	
	controlinfo/w=$panelN $("portStatusSetVar_"+panelN)
	
	if (stringmatch(s_value,"READY"))
		return 1
	endif
	
	if (stringmatch(s_value,"BUSY"))
		return 2
	endif
	
	if (stringmatch(s_value,"*CLOSED*"))
		teensy_gui_postMessage(panelN,"PORT: is CLOSED, blocking communication. Click on Port to attempt connection",0)
		return -1
	endif
	
	if (tryConnect)
		return teensy_gui_setConnection(panelN,1)
	endif
	
	
	return 0		//connection not ok and no reconnect attempt was requested

end

function teensy_gui_postMessage(panelN,message,echoToCmdLine)	
	String panelN,message
	int echoToCmdLine		//should be used for messages that represent true, non-user-drive ERRORS
	
	gui_pushToTopOfPopupValueStr(panelN,"messagePopup_"+panelN,message,1)
	if (echoToCmdLine)
		print "teensy_gui_postMessage() echo message:",message
	endif
end

function gui_pushToTopOfPopupValueStr(winN,popupName,pushStr,ignoreRepeats)		//apparently limited to 2400 bytes (characters, so let's keep as much as we can)
	String pushStr		//new string to put at front of list
	String winN,popupName
	int ignoreRepeats		//pass 1 to skip push if this value is already at the top of the "stack"
	
	String valueStr = gui_getPopupValueStr(winN,popupName)
	String currentTopStr = stringfromlist(0,valueStr)
	int isEmphasis = str2num(getuserdata(winN,popupName,"emphasis"))
	if (ignoreRepeats && stringmatch(pushStr,currentTopStr))		//dont include the match, can just return
		popupmenu $popupName win=$winN,fstyle=(!isEmphasis)*(2^1+2^2),userdata(emphasis)=num2str(!isEmphasis)	//toggle emphasis to indicate the action reoccured
		return 0
	endif
	
	String quote = "\""
	valueStr = quote+list_trimToCharLimit(pushStr+";"+valueStr,2050)+quote	//need to stay well under the 2500 character limit apparently
	popupmenu $popupName win=$winN,value=#valueStr
end

function/s gui_getPopupValueStr(winN,popupName)
	String winN,popupName
	
	ControlInfo/w=$winN $popupName
	return stringfromlist(1,StringByKey("value",S_recreation,"=",","),"\\\"")		//works so far empirically
end

function/s list_trimToCharLimit(list,charLimit)
	String list		//list to remove items from end of until under char limit
	Variable charLimit		//limit to num characters allowed -- equivalent to number of bytes allowed
	
	int items
	do
		if (strlen(list) <= charLimit)
			return list	//return successfully trimmed list
		endif
		
		items = itemsinlist(list)
		list = removelistitem(items-1,list)		//remove last item
	while (items > 1)		//
	
	return ""		//items == 1; last item was just removed, return empty string
end
	
function teensy_gui_btnHandling(s) : ButtonControl
	STRUCT WMButtonAction &s
	
	if (s.eventCode != 2)	//only respond to mouse up (while still over button) after click down on button
		return 0
	endif
	

	strswitch (s.ctrlName)
		case "sendIvRel":
			variable sendIv = 1
			prompt sendIv,"Send I(V) relation (red trace) to Teensy? WARNING: SLOWS ANY ONGOING ARBITRARY CLAMP"
			doprompt "Really send I(V) despite slowing? (1 for yes, 0 for no)",sendIv
			if (!V_flag && sendIV)
				teensy_gui_sendFloats(s.win,"ivRel_toSend",0,1)		//send iv rel
			endif
		
			break
		
		case "autoCalibrate":
			Variable runCalibration = 1
			prompt runCalibration, "Auto calibrate Teensy? (1 for yes, 0 for no). WARNING: REQUIRES IGOR NIDAQ BOARD CONTROL TEENSY MEMBRANE READ INPUT, NOT AMPLIFIER!"
			doprompt "Run autocalibration?",runCalibration
			String comStr = getuserdata(s.win,"","comStr")
			if (!V_flag && runCalibration)
			#if (exists("fdaqmx_writechan"))		//only compile of daq procs are available via the xop	
				teensyCal_doCals(comStr,"",portIsConnected=1)
			#else
				print "Cannot autocalibrate without Igor DAQMX tools (fdaqmx)"
			#endif	
			endif 
			
			break
		
	endswitch
end

strconstant ks_teensyFloatsRespBgTaskStartStr = "sendFloatsBgTask_"
function teensy_gui_sendFloats(panelN,targetWvRef,copyIntoDF,sendingIv)
	String panelN
	STring targetWvRef		//reference to wave to send. if copyIntoDF==0, should be stored in the package data folder.
	int copyIntoDF		//pass 1 to copy the wave from the current working directory to the pacakge folder and then send it
							//cannot send a free wave because sending continues in a background function, so the free wave cannot be maintained
	int sendingIv		//pass 1 if sending an iv, provides more useful error messaging and updating of the GUI						
	
	String folderPath = getUserdata(panelN,"","folderPath")
	String sendRef = folderPath + ":" + targetWvRef
	if (copyIntoDF)
		WAVE toCopy = $targetWvRef
		duplicate/o toCopy,$sendRef
	else
		WAVE/Z sendWv = $sendRef
		if (!WaveExists(sendWv))
			print "teensy_gui_sendFloats() error! Aborting because targetWvRef",targetWvRef,"not in data folder"
			return 0;
		endif
	endif
	
	int ok = teensy_gui_isReadyToSend(panelN,0)
	if (!ok)
		return 0
	endif
	
	//set Port status to busy until we're done, so that new commands don't interrupt the I(V) send, which involves multiple sends
	teensy_gui_setResponseWaitStatus(panelN,1)		//will be set to zero when the background task ends
	
	//set up task -- create if it does not already exist
	String taskName = ks_teensyFloatsRespBgTaskStartStr+panelN
	String bgTasks = background_getTaskList()	//this function checks indirectly, quererying CtrlNamedBackground_all_, This is good because checking directly actually CREATES the task
	if (whichlistitem(taskName,bgTasks) < 0)		//task not yet created
		CtrlNamedBackground $taskName,period=k_pollingFrequency_ticks,proc=teensy_gui_sendFloatsBg,start=0		//3x slower than the tighter-loop polling function this function calls, do not start polling immediately
	endif
	
	setwindow $panelN,userdata(sendFloats_waveName)=sendRef
	setwindow $panelN,userdata(sendingIv)=num2str(sendingIv)
	setwindow $panelN,userdata(sendFloatsNumIters)="0"		//tracks how far along in sending we are
	setwindow $panelN,userdata(currFloatsSendIndex)="0"		//tracks how far along in sending we are
	String ticksStr;sprintf ticksStr,"%d",ticks
	setwindow $panelN,userdata(sendFloatsBg_startTicks)=ticksStr	
	setwindow $panelN,userdata(sendFloatsBg_dataSent)="0"		//lets the BG function know whether it should wait for a response
	
	CtrlNamedBackground $taskName,start=1		//start polling now
end


//calls sendOneSetOfFloats over and over again, sending a wave of float points in pieces
static constant k_sendFloatsBgWaitTimeLimit_ticks = 40000//600//1200		//20 second limit; empirally 8-9 secs right now		
function teensy_gui_sendFloatsBg(s)
	STRUCT WMBackgroundStruct &s
	
	String panelN = removelistitem(0,s.name,"_")
	String sendRef = getuserdata(panelN,"","sendFloats_waveName")
	int sendingIv = str2num(GetUserData(panelN,"","sendingIv"))
	int startTicks = str2num(GetUserData(panelN,"","sendFloatsBg_startTicks"))
	int currFloatsSendIndex=str2num(getuserdata(panelN,"","currFloatsSendIndex"))		//used to track position in array to send
	int dataSent = str2num(getuserdata(panelN,"","sendFloatsBg_dataSent"))
	int sendFloatsNumIters = str2num(GetUserData(panelN,"","sendFloatsNumIters"))	
	String comStr = getuserdata(panelN,"","comStr")
	
	//check for time out
	int currTicks =ticks 
	if ( (currTicks-startTicks) > k_sendFloatsBgWaitTimeLimit_ticks)
		teensy_gui_postMessage(panelN,"teensy_gui_sendFloatsBg() unexpected TIME OUT before finished sending I(V) response! # sendFloatsNumIters beforehand="+num2str(sendFloatsNumIters)+". currFloatsSendIndex="+num2str(currFloatsSendIndex),1)
		teensy_gui_setResponseWaitStatus(panelN,0)
		return 1		//stop task				
	endif
	
	//check whether a response is available and read if so
	if (dataSent)
		int bytesAvailable=teensy_bytesAvailable(comStr)
		if (bytesAvailable < 1)		//need to keep waiting
			setwindow $panelN,userdata(sendFloatsNumIters)=num2str(sendFloatsNumIters+1)
			return 0
		else		//bytes are available, read them and continue
			int success = teensy_gui_readFloats(panelN)
			teensy_gui_updateFromTeensyResponse(panelN)
			if (!success)
				teensy_gui_postMessage(panelN,"teensy_gui_sendFloatsBg() expected to read data and then failed to do so! Continuing for now...",1)
				setwindow $panelN,userdata(sendFloatsNumIters)=num2str(sendFloatsNumIters+1)
				return 0
			endif
			dataSent = 0;
			setwindow $panelN,userdata(sendFloatsBg_dataSent)="0"
		endif
	endif
	
	//should get here if data not sent or we just read data
	
	//if we're here, data was read (or it's the first iteration and we need to send). So send the next bit
	String folderPath = getUserdata(panelN,"","folderPath")
	WAVE fullSendWv=$sendRef
	int pnts = dimsize(fullSendWv,0)
		
	//figure out how far into the send we are 	-- if complete, closeout transfer (stop task, set wait status to not waiting)
	if (currFloatsSendIndex >= pnts)		//we're done! close out transfer
		Variable elapsedSecs = (ticks - startTicks)/60
		String msg = "teensy_gui_sendFloatsBg() " + selectstring(sendingIv,"floats","iv") +" sent successfully! Time required (s)="+num2str(elapsedSecs)
		teensy_gui_postMessage(panelN,msg,0)
		
		if (sendingIv)
			duplicate/o fullSendWv,$(folderPath+":ivRel_lastSent")		//store that this I(V) has been sent
			teensy_gui_updateLeakRel(panelN)
		endif
		
		teensy_gui_setResponseWaitStatus(panelN,0) //clear response wait status
		setwindow $panelN,userdata(sendFloatsNumIters)=num2str(sendFloatsNumIters+1)
		return 1		//stops task
	endif
	
	int endIndex = currFloatsSendIndex + k_floatsPerStandardDataTransfer - 1		//if maximum sendable ever increases and becomes different than this constant, can increase this
	if (endIndex >= pnts)		//last run
		endIndex = pnts -1
	endif
	
	int numToSend = endIndex - currFloatsSendIndex + 1
	make/o/free/n=(k_floatsPerStandardDataTransfer) currSendWv		//always going to send max number, even if there's just one point remaining. We'll pad with NaNs
	currSendWv[0,numToSend-1] = fullSendWv[currFloatsSendIndex+p]
	if (numToSend < k_floatsPerStandardDataTransfer)
		currSendWv[numToSend,]=nan
	endif
	
	//clear serial i/o
	vdt2/p=$comStr killio
	
	//send data
	int V_VDT = teensy_sendBinary(currSendWv)
	if (V_VDT < 1)
		teensy_gui_postMessage(panelN,"Send settings: failed unexpectedly after VDTWriteBinaryWave2 in teensy_sendOneSetOfFloats()!!!",1)
		return 1
	endif
			
	//iterate sendIndex -- once endIndex is set to pnts - 1, endIndex will be set to == pnts, so the next iteration will terminate
	setwindow $panelN,userdata(currFloatsSendIndex)=num2str(endIndex+1)
	setwindow $panelN,userdata(sendFloatsNumIters)=num2str(sendFloatsNumIters+1)
	setwindow $panelN,userdata(sendFloatsBg_dataSent)="1"
	return 0 	//continue 
end

//send float data to the teensy, then
//begin a background function that will check for response from teensy and update GUI accordingly
//return 0 if failed to start background function, 1 if started successfully
static constant k_pollingFrequency_ticks = 1		//poll as quickly as possible, every ~6 ms
static constant k_backgroundWaitTimeLimit_ticks = 240		//wait only up to 4 secs (Was getting some time-out at 2s)
static strconstant ks_teensyFloatRespBgTaskStartStr = "teensyFloatRespBgTask_"
function teensy_sendOneSetOfFloats(panelN,wv,ignoreWaitingForResponse,doNotClearWaitingStatus,[noReceiveBg])
	String panelN	//teensy GUI panelN
	WAVE wv
	int ignoreWaitingForResponse		//pass 1 to ignore waiting for response -- should be used with extreme caution. Intended for leaving the busy signal on during multiple sends, like the i(v) relation
	int doNotClearWaitingStatus		//pass 1 in order to NOT clear waiting status after finishing read from teensy -- should also be used w/ extreme caution. Also intended for leaving busy signal on during multiple sends
	int noReceiveBg		//pass 1 to avoid starting a background function to poll for results
	
	int doReceiveBg = paramisdefault(noReceiveBg) || !noReceiveBg
	
	if (strlen(panelN) < 1)
		panelN = winname(0,64)	//top panel
	endif
	
	
	int numToSend = dimsize(wv,0)
	if (numToSend != k_floatsPerStandardDataTransfer)
		teensy_gui_postMessage(panelN,"teensy_sendOneSetOfFloats() ERROR float wave passed to send "+nameofwave(wv)+" has incorrect length, aborting",1)
		return 0
	endif
	
	int ok = teensy_gui_isReadyToSend(panelN,ignoreWaitingForResponse)
	if (!ok)
		return 0
	endif
		
	if (doReceiveBg)
		String taskName = ks_teensyFloatRespBgTaskStartStr+panelN		
		String bgTasks = background_getTaskList()
		int taskExists = whichlistitem(taskName,bgTasks) >= 0
		//create the task if it doesnt exist
		if (!taskExists)
			CtrlNamedBackground $taskName,period=k_pollingFrequency_ticks,proc=teensy_gui_serialPollBg,start=0		//do not start polling immediately
		endif
		
		//clear serial i/o
		String comStr = getuserdata(panelN,"","comStr")
		vdt2/p=$comStr killio
	endif
	
	//send data
	int V_VDT = teensy_sendBinary(wv)
	if (V_VDT < 1)
		teensy_gui_postMessage(panelN,"Send settings: failed unexpectedly after VDTWriteBinaryWave2 in teensy_sendOneSetOfFloats()!!!",1)
		return 0
	endif
	
	if (!doReceiveBg)		//all done if dont need to start background task
		return 1
	endif
	
	teensy_gui_setResponseWaitStatus(panelN,1)		//set to busy/waiting for response -- this will be set to zero when the background task ends
	
	//record current start ticks and other preferences
	setwindow $panelN,userdata(bgPollCount)="0"
	String ticksStr
	int currTicks = ticks
	sprintf ticksStr,"%d",currTicks
	setwindow $panelN,userdata(serialPollBg_startTicks)=ticksStr
	setwindow $panelN,userdata(serialPollBg_doNotClearWaitingStatus)=num2str(doNotClearWaitingStatus)
	
	//start (or re-start) polling
	CtrlNamedBackground $taskName,start=1
	
	return 1
end

//meant to be very low level. vdt port must be set ahead of time
function teensy_sendBinary(wv)
	WAVE Wv
	
	VDTWriteBinaryWave2/B/O=(3)/TYPE=(2)/Q wv
	return V_VDT
end

function teensy_gui_setResponseWaitStatus(panelN,waiting)
	String panelN
	int waiting		//1 for waiting, 0 for not waiting
	
	int connectionOk = teensy_gui_getConnectionStatus(panelN,0)		//0 or less for unconnected, in which case the waiting status is zero no matter what the intput is
	if (connectionOk <= 0)
		setwindow $panelN,userdata(waitingForResponse)="0"
		//leave port status string unchanged 
		return 0	
	endif
	
	setwindow $panelN,userdata(waitingForResponse)=num2str(waiting)	
	if (waiting)
		setvariable $("portStatusSetVar_"+panelN) win=$panelN,value=_STR:"BUSY"
	else
		setvariable $("portStatusSetVar_"+panelN) win=$panelN,value=_STR:"READY"
	endif
end

function teensy_gui_isReadyToSend(panelN,ignoreWaitingForResponse)
	String panelN
	int ignoreWaitingForResponse		//pass 1 to ignore waiting for response -- should be used with extreme caution. Intended for leaving the busy signal on during multiple sends, like the i(v) relation
	
	int connectionOk = teensy_gui_getConnectionStatus(panelN,1)		//1 means ready. 2 means busy (handled by waiting and should be ignored
	if (connectionOk <= 0)
		teensy_gui_postMessage(panelN,"teensy_gui_isReadyToSend(): Send or receive failed, teensy is not connected. Try clicking on 'Port'",0)
		return 0
	endif
	
	if (!ignoreWaitingForResponse)		//skip this if requested
		//do not start new i/o if we're still polling for another response
		int waitingForResponse = str2num(getUserData(panelN,"","waitingForResponse"))
		if (waitingForResponse)
			teensy_gui_postMessage(panelN,"teensy_gui_isReadyToSend(): Send or receive failed, teensy port is BUSY sending something else",0)
			return 0
		endif
	endif

	return 1
end

//check for responses and update GUI when received -- this is created the first time teensy_gui_startSerialPolling() is called then paused in between reads 
function teensy_gui_serialPollBg(s)
	STRUCT WMBackgroundStruct &s
	
	String panelN =removelistitem(0,s.name,"_")
	int startTicks = str2num(GetUserData(panelN,"","serialPollBg_startTicks"))
	int bgPollCount = str2num(GetUserData(panelN,"","bgPollCount"))
	//check for time out
	int currTicks = ticks;
	if ( (currTicks-startTicks) > k_backgroundWaitTimeLimit_ticks)
		teensy_gui_postMessage(panelN,"teensy_gui_serialPollBg() unexpected TIME OUT before receiving teensy response! # poll attempts beforehand="+num2str(bgPollCount),1)
		//print "startTicks",startTicks,"currTicks",currTicks,"diff",currTicks-startTicks,"limit ticks",k_backgroundWaitTimeLimit_ticks
		teensy_gui_setResponseWaitStatus(panelN,0)
		return 1		//stop task				
	endif
	
	//attempt to read
	int connectionOk = teensy_gui_getConnectionStatus(panelN,0)
	if (connectionOk <= 0)		//connection status should be busy
		teensy_gui_postMessage(panelN,"teensy_gui_serialPollBg() unexpected CONNECTION UNAVAILABLE before receiving teensy response! # poll attempts beforehand="+num2str(bgPollCount),1)
		teensy_gui_setResponseWaitStatus(panelN,0)
		return 0
	endif
	String comStr = getUserData(panelN,"","comStr")
	
	if (teensy_bytesAvailable(comStr) < 1)  //continue to wait
		setwindow $panelN,userdata(bgPollCount)=num2str(bgPollCount+1)
		
		return 0
	else		//bytes are available
		int success = teensy_gui_readFloats(panelN)
		if (!success)
			teensy_gui_postMessage(panelN,"teensy_gui_serialPollBg() expected to read data and then failed to do so! Continuing for now...",1)
			setwindow $panelN,userdata(bgPollCount)=num2str(bgPollCount+1)
			return 0
		endif
	endif
	
	String response
	
	//update some basic info
	
	//setwindow $panelN,userdata(lastTeensyResponse)=response
	//setwindow $panelN userdata(lastTeensyClampStatus)=StringByKey("status",response,":","|")
	int numItemsReturnedByTeensy = str2num(getuserdata(panelN,"","numItemsReturnedByTeensy"))+1
	String numItemsStr;sprintf numItemsStr,"%d",numItemsReturnedByTeensy		//avoid rounding
	setwindow $panelN,userdata(numItemsReturnedByTeensy)=numItemsStr
	setwindow $panelN,userdata(bgPollCount)=num2str(bgPollCount+1)
	
	//update gui based on output
	teensy_gui_updateFromTeensyResponse(panelN)
	
	//clear busy signal unless requested not to (that information is conveyed in task name)
	int doNotClearWaitingStatus = str2num(GetUserData(panelN,"","serialPollBg_doNotClearWaitingStatus"))
	if (!doNotClearWaitingStatus)
		teensy_gui_setResponseWaitStatus(panelN,0)
	endif
	
	return 1	//stop task	
		
end

function teensy_gui_readFloats(panelN)		//read floats that teensy sends. Meant only to be called when bytes are confirmed to be available
	String panelN
	
	String folderPath = getUserdata(panelN,"","folderPath")
	WAVE respWv = $(folderPath+":lastTeensyResponse")		//could add /z and make one if doesnt exist, but really should exist for sure as is! except for disruptive user..
	teensy_readOneFloatSetDuringExecution(respWv=respWv)
end

constant k_calibration_typeNum = 0		//must match expected spcial case type number in sketch
function teensy_gui_sendCalibration(panelN,bypassNonLiveMode)
	String panelN		//starts a background task that confirms successful send
	int bypassNonLiveMode		//passing 1 only recommended if you are sure you know what you're doing!
	
	if (strlen(panelN) < 1)
		panelN = winname(0,64)	//top panel
	endif
	
	String folderPath = getUserdata(panelN,"","folderPath")
	WAVE/Z calibrationWv = $(folderPath+":calibrationWv")
	if (!WaveExists(calibrationWv))
		teensy_gui_postMessage(panelN,"teensy_gui_sendCalibration() no calibrationWv!! Teensy innacurate. Run teensyCal_doCals() after switching to NIDAQ control",1)
		return 0
	endif
	
	int calCols = dimsize(calibrationWv,1)		//right-most column contains most up-to-date
	duplicate/o/free/r=[][calCols-1] calibrationWv,calTemp;redimension/n=(-1) calTemp
	insertpoints/m=0/v=(NaN) 0,3,calTemp; calTemp[2] = k_calibration_typeNum
	int pnts = dimsize(calTemp,0)
	int neededPnts = k_floatsPerStandardDataTransfer - pnts
	if (neededPnts > 0)		//pnts should be 4 but can be up to k_floatsPerStandardDataTransfer and no longer
		InsertPoints/M=0/V=(NaN)  pnts+1, neededPnts,calTemp		//pad length to k_floatsPerStandardDataTransfer with nan
	elseif (neededPnts < 0)	//really shouldnt happen
		redimension/n=(k_floatsPerStandardDataTransfer) calTemp
		teensy_gui_postMessage(panelN,"teensy_gui_sendCalibration() calibrationWv unexpected very long, longer than k_floatsPerStandardDataTransfer, but 4 points expeted! whats going on??!! Teensy may be innacurate. Run teensyCal_doCals() after switching to NIDAQ control",1)
	endif
	teensy_gui_sendSettings(panelN,bypassNonLiveMode,customSettingsWv=calTemp)
end

static constant k_recordStep_typeNum = 3		//must match expected spcial case type number in sketch
function teensy_gui_recordSteps(panelN,numSteps,stepMicros,baselineCurrent,stepCurrent)
	String panelN
	int numSteps			//number of steps to average (or 1 for single trial, which is fine)
	int stepMicros		//microseconds at which step starts. available precision is that of clamp steps (3-5 microseconds)
	Variable baselineCurrent		//pre-step current
	Variable stepCurrent	//current during step
	
	if (strlen(panelN) < 1)
		panelN = winname(0,64)	//top panel
	endif
	String comStr = getUserData(panelN,"","comStr")
	String folderPath = "root:Packages:"+panelN
	
	make/o/n=(16) sendWv
	sendWv[0,1] = nan; sendWv[2] = k_recordStep_typeNum;
	sendWv[3] = stepMicros
	sendWv[4] = baselineCurrent
	sendWv[5] = stepCurrent
	sendWv[6,]=nan

	int i,sent,totalData,numSamples,endMicros,ready
	Variable timeoutTicks = inf
	
	for (i=0;i<numSteps;i++)
		do
			if ( ticks > timeoutTicks )
				print "teensy_gui_recordSteps() teensy remained busy, unable to record multiple step responses!"
				return 0
			endif	
		while (!teensy_gui_isReadyToSend(panelN,0))		//is the gui/teensy busy?
	
		sent = teensy_gui_sendSettings(panelN,1,customSettingsWv=sendWv,noReceiveBg=1)
		if (!sent)
			print "teensy_gui_recordStep() did not proceed, likely because teensy is busy"
			return 0
		endif
		
		WAVE responses = teensy_readDuringExecution(comStr,nan)
		
		teensy_gui_sendSettings(panelN,0)		//I dont know why, but sending a settings update helps if the user is going to run this twice in a row												
		totalData = responses[0]	
		numSamples = floor((totalData - 1)/2)
		duplicate/o/r=[1,1+numSamples-1] responses,$(folderPath+":lastStepDts")/wave=lastStepDts
		duplicate/o/r=[1+numSamples,1+2*numSamples-1] responses,$(folderPath+":lastStepVoltageResp")/wave=lastStepVoltageResp
		
		//unwrap timing
		lastStepDts[0] = 0
		lastStepDts[1,] = lastStepDts[p-1] + lastStepDts[p]
		
		//interpolate to 1 microsecond (more useful for averaging than for not)
		if (numSteps > 1)
			if (i==0)
				endMicros = lastStepDts[dimsize(lastStepDts,0)-1]-20		//some might end slightly later or earlier, but we can loose a bit of the end
				make/o/d/free/n=(endMicros) interpTemp;
				setscale/p x,0,1e-6,"s",interpTemp
			endif

			interpTemp=interp(p,lastStepDts,lastStepVoltageResp)
			
			if (i==0)
				duplicate/o/free interpTemp,allInterps
			else
				concatenate/np=1 {interpTemp},allInterps
			endif
			
			timeoutTicks = ticks + k_backgroundWaitTimeLimit_ticks;		//to see how long we've been waiting during next iteration 
		endif	
		
	endfor		
		
	if (numSteps > 1)
		matrixtranspose allInterps		//orient to get stats across replicates
		wavestats/pcst allInterps
		WAVE M_wavestats; 
		matrixtranspose M_wavestats
		duplicate/o M_Wavestats,$(folderPath+":lastStepVoltageRespAvg")/wave=lastStepVoltageRespAvg
		setscale/p x,0,1e-6,"s",lastStepVoltageRespAvg
		killwaves/z M_wavestats
	endif
	
end 


//FOR CALIBRATION

#if (exists("fdaqmx_writechan"))		//only compile of daq procs are available via the xop	

static constant k_teensyNumReadReturns = 30		//how many reads does the teensy return when prompted (set by its .ino sktch)
static constant k_teensyReadSetsToAvg = 100 //how many sets of teensy reads to average (each set has reads = k_teensyNumReadReturns) 
static constant k_teensyReturnTimeOutSecs = 5		//give up even teensy takes longer than this to return over serial i/o
static constant k_cmdResolutionRange = 2	//how many volts around command value to put, nidaqmx tools scale to use gain better for accuracy
static constant k_waitAfterNewLevelSecs = 0.3		//how long to wait between new command values

static constant k_dacSampleRate = 10000
static constant k_dacAvgNum = 10		//dac is capable of averaging 10 samples even at 10kHz, supposedly
static constant k_dacAvgLenSecs = 0.2	//2 //number of seconds to average


//runs input-side and output-side calibration, stores calibration results for teensy GUI to send to teensy upon start / continue
function teensyCal_doCals(comStr,statsRefStartStr,[skipCalAndForceSavingThisWv,portIsConnected])
	String comStr		//teensy communication port
	String statsRefStartStr			//pass "" for default name, which is date specific
	WAVE skipCalAndForceSavingThisWv
	int portIsConnected		//pass 1 if port is connected. Will keep it so. Otherwise pass 0, in which case automatically connects to comStr and disconnects after
	
	if (strlen(comStr) < 1)
		comStr = ks_teensyCom
	endif
	
	int doCal = PAramIsDefault(skipCalAndForceSavingThisWv)
	portIsConnected = paramisdefault(portIsConnected) ? 0 : portIsConnected
	
	String lbl = "date="+date()+";time="+time()+";"
	
	if (strlen(statsRefStartStr) < 1)
		statsRefStartStr = "TeensyCal_" + getDateStr("")
	endif
	
	String inputStatsRef=statsRefStartStr+"_input_dac0",outputStatsRef=statsRefStartStr+"_output"
	if (doCal)
		print "teensyCal_doCals() starting teensyCal_inputCal()"
		WAVE inputCalWv = teensyCal_inputCal(comStr,inputStatsRef,portIsConnected)		//currently running on dac0 by default, others not configured
		print "teensyCal_doCals() starting teensyCal_outputCal() in 3 seconds..."
		sleep/s 1
		WAVE outputCalWv = teensyCal_outputCal(comStr,outputStatsRef,portIsConnected)
		concatenate/dl/np=(0)/free/o {inputCalWv,outputCalWv},calWvs_combined
	else
		duplicate/o/free skipCalAndForceSavingThisWv,calWvs_combined
	endif

	//store calibration data in a folder  -- may have to build folder since panel may not exist
	String panelN = "teensy_clamp_" + comStr
	String folderPath = "root:Packages:"+panelN
	NewDataFolder/o root:Packages
	newDataFolder/o $folderPath
	WAVE/Z calibrationWv = $(folderPath+":calibrationWv")
	int col
	if (!WaveExists(calibrationWv))
		duplicate/o calWvs_combined,$(folderPath+":calibrationWv")/wave=calibrationWv
		redimension/n=(-1,1) calibrationWv
		col = 0
	else
		col = dimsize(calibrationWv,1)
		concatenate/dl/np=(1) {calWvs_combined},calibrationWv
	endif
	setdimlabel 1,col,$lbl,calibrationWv
	note calibrationWv,"inputStatsRef:"+inputStatsRef+";outputStatsRef:"+inputStatsRef+";"
end

function/wave teensyCal_inputCal(comStr,statsRef,portIsConnected)
	String comStr
	String statsRef		//save results. also displays to 
	int portIsConnected
	
	if (strlen(comStr) < 1)
		comStr = ks_teensyCom
	endif
	
	Variable input_membrane_mV_per_amplifier_V = 1000/input_amplifier_mV_per_membrane_mV		//easier to invert and convert to mV membrane potential per V amplifier change since we can read that in raw volts
	
	STring dispWinName = statsRef + "_inputCalWin"
	
	//additional parameters for calibration. Could move these to the function declaration
	Variable vMin = -9.8,vMax=9.8		//min is -10,max is +10 
	Variable vEnd = 0		//where to put value at end
	Variable vFitStart=vMin,vFitEnd=vMax		//not necessarily linear throughout range, range to fit for linearity of gain
	Variable numAdditionalLevels=14		//# linearly distributed levels to test between vMin and vMax
	
	Variable numLevels = 2+ numAdditionalLevels		//vMin and vMax plus any additional
	
	//connect to teensy and ensure that it is not in running mode
	if (!portIsConnected)
		vdtoperationsport2 $comStr;VDT2/P=$comStr baud=k_comBaud;
	endif
	
	int off = teensyCal_setRunningModeOffDuringExecution(comStr)
	if (!off)
		print "teensyCal_inputCal() failed to set teensy running mode to off! calibration may fail / look like a flat relationship. May need to reload sketch onto teensy"
	endif
	
	//waves to hold results
	String statTypeDescs="cmdVoltage;teensyInputVoltage;equivMemVoltage;teensyReads"
	int numStatTypes = itemsinlist(statTypeDescs)
	make/o/d/n=(4)/free/W wstest; wavestats/q/w wstest;WAVE M_wavestats;Variable numStats = dimsize(M_wavestats,0)	//just find out how many rows there are in wavestats output
	make/o/d/n=(numLevels,numStats,numStatTypes) $statsRef/wave=stats; stats = nan
	setscale/I x,vMin,vMax,stats		//assign level scaling (and let Igor calculate intermediate levels)
	copydimlabels/rows=1 M_wavestats,$statsRef
	dl_assignLblsFromList(stats,2,0,statTypeDescs,"",0)		//assign layer labels -- order must stay or else update fit code below
	
	//make waves to store raw reads from the command and input copies going into the dac,setup reading into them
	Variable avgPnts = k_dacAvgLenSecs * k_dacSampleRate
	make/o/d/n=(avgPnts) cmdCopy,inputCopy
	make/o/d/n=(4) cmdWaveform		//fdaqmx_writeChan seems to be failing to complete before returning, trying to write a wave with the commanded value
	setscale/p x,0,1/k_dacSampleRate,"s",cmdCopy,inputCopy,cmdWaveform
	Variable ok = fDAQmx_ScanStop(ks_dacName)		//assure not already scanning
	
	//run the calibration
	int i;Double level,rangeMinV,rangeMaxV
	make/o/free/n=(numLevels+1,10) daqErrors = nan	//error tracing
	String winN
	for (i=0;i<numLevels;i+=1)
		level = pnt2x(stats,i)
		rangeMinV = min(level-k_cmdResolutionRange/2,-10)	//mostly a nidaq quirk that has to be dealt with, see fdaqmx_writechan
		rangeMaxV = max(level+k_cmdResolutionRange/2,10)		//mostly a nidaq quirk that has to be dealt with, see fdaqmx_writechan
		cmdWaveform = level
		daqErrors[i][0]=fDAQmx_WaveformStop(ks_dacName)
		DAQmx_WaveformGen/DEV=ks_dacName/NPRD=0/STRT=1 "cmdWaveform, "+num2str(k_teensyCmdChanNum)+";"	
		doupdate;sleep/s k_waitAfterNewLevelSecs;doupdate;	//let things settle (shouldnt be strictly necessary)
		daqmx_scan/DEV=ks_dacName/AVE=(k_dacAvgNum)/STRT=1/BKG/EOSH="print \"scan complete\""  WAVES=("cmdCopy,"+num2str(k_teensyCmdCopyChanNum)+";inputCopy,"+num2str(k_teensyInputCopyChanNum)+";")
			//get and store teensy reads
		WAVE teensyReadSet = teensyCal_getReadSet(comStr)		//get teensy reads
		WAVESTATS/q/w teensyReadSet; stats[i][][%teensyReads]=M_wavestats[q]
			//get and store dac reads
		daqErrors[i][2]  = fDAQmx_ScanWait(ks_dacName)	//wait til cmdCopy and inputCopy have been filled
			//raw read stats
		wavestats/q/w cmdCopy; stats[i][][%cmdVoltage]=M_wavestats[q]
		wavestats/q/w inputCopy;stats[i][][%teensyInputVoltage]=M_wavestats[q]
			//scaled stats
		stats[i][%avg][%equivMemVoltage]=stats[i][%avg][%cmdVoltage]*input_membrane_mV_per_amplifier_V
		stats[i][%sdev][%equivMemVoltage]=stats[i][%sdev][%cmdVoltage]*input_membrane_mV_per_amplifier_V
		stats[i][%sem][%equivMemVoltage]=stats[i][%sem][%cmdVoltage]*input_membrane_mV_per_amplifier_V
				
		//output
		if (i==0)
			killwindow/Z $dispWinName
			display/k=1/N=$dispWinName stats[][%avg][%teensyReads]/tn=teensyReads vs stats[][%avg][%equivMemVoltage]
			winN=s_name
			appendtograph/w=$winN/l=L_input stats[][%avg][%teensyInputVoltage]/tn=teensyInput vs stats[][%avg][%equivMemVoltage]
			appendtograph/w=$winN/l=left_sdev/b=bottom_sdev2 stats[][%sdev][%teensyReads]/tn=teensyReads_sdev vs stats[][%sdev][%teensyInputVoltage]
			appendtograph/w=$winN/l=L_input_sdev/b=bottom_sdev stats[][%sdev][%teensyInputVoltage]/tn=teensyInput_sdev vs stats[][%sdev][%equivMemVoltage]
			errorbars/w=$winN/T=0/L=0.6/RGB=(0,0,0) teensyReads,xy,wave=(stats[][%sdev][%equivMemVoltage],stats[][%sdev][%equivMemVoltage]),wave=(stats[][%sdev][%teensyInputVoltage],stats[][%sdev][%teensyInputVoltage])		//error bars of sdev for x and y
			errorbars/w=$winN/T=0/L=0.6/RGB=(0,0,0) teensyInput,xy,wave=(stats[][%sdev][%equivMemVoltage],stats[][%sdev][%equivMemVoltage]),wave=(stats[][%sdev][%teensyInputVoltage],stats[][%sdev][%teensyInputVoltage])		//error bars of sdev for x and y
			modifygraph/W=$winN axisenab(bottom)={0,0.4},axisenab(bottom_sdev)={0.61,1},axisenab(bottom_sdev2)={0.61,1}
			modifygraph/w=$winN freepos=0,lblpos=52,axisenab(left)={0.55,1},axisenab(l_input)={0,0.45}
			modifygraph/w=$winN freepos=0,lblpos=52,axisenab(left_sdev)={0.62,1},axisenab(l_input_sdev)={0,0.38}
			Label/w=$winN left "Teensy reads";Label/w=$winN bottom "Mem voltage";Label/w=$winN L_input "Scaled voltage"
			Label/w=$winN left_sdev "Read SDEV (raw)";Label/w=$winN bottom_sdev "Input Mem voltage SDEV (mV)\\u#2";
			ModifyGraph/w=$winN prescaleExp(L_input_sdev)=3,prescaleExp(bottom_sdev)=3;Label/w=$winN L_input_sdev "SDEV (mV)\\u#2";//show in mV
			Label/w=$winN bottom_sdev2 "Scaled input SDEV \\U"
			ModifyGraph/w=$winN freePos(L_input_sdev)={0,bottom_sdev},freePos(left_sdev)={0,bottom_sdev2},freepos(bottom_sdev2)={0,left_sdev},lblPos(bottom_sdev2)=33
			ModifyGraph/w=$winN mode(teensyReads)=4,marker(teensyReads)=19,msize(teensyReads)=1,mode(teensyInput)=4,marker(teensyInput)=19,msize(teensyInput)=1		//dots for points
		endif
		doupdate;Print "teensyCal_inputCal() completed level #=",i,"level=",level
	endfor
	
	if (!portIsConnected)
		vdtcloseport2 $comStr
	endif
	
	daqErrors[i][0] =fdaqmx_writechan(ks_dacName,k_teensyCmdChanNum,vEnd,rangeMinV,rangeMaxV)	//command the level as output -- not sure why but this isnt working
	
	
	//fit line to input-output relation
	Variable avgCol = finddimlabel(stats,1,"avg")
	Variable equivMemVoltageLayer = finddimlabel(stats,2,"equivMemVoltage")
	Variable teensyReadLayer = finddimlabel(stats,2,"teensyReads")
	STring coefsSafeRef = statsRef +"_coefs"
	make/o/d/n=(2) $coefsSafeRef/wave=coefs
	curvefit/n line, kwcwave=coefs, stats[][avgCol][teensyReadLayer]/x=stats[][avgCol][equivMemVoltageLayer]/d //vs stats(vFitStart,vFitEnd)[%avg][%teensyReads]
	ModifyGraph/w=$winN rgb($("fit_"+statsRef))=(1,4,52428)
	
	Double slope = coefs[1],offset=coefs[0]
	print "convert from teensy reads with: (Mem voltage)=((teensyRead)-(offset))/(slope); (Mem voltage)=((teensyRead)-("+num2str(offset)+"))/("+num2str(slope)+")"
	//use scaling to convert read SDEV into read mV sdev
	modifygraph/w=$winN muloffset(teensyReads_sdev)={0,1/slope};Label/w=$winN left_sdev "Read SDEV (mV)\\u#2";
	
	make/o/d/free out = {slope,offset}
	dl_assignlblsfromlist(out,0,0,"inputCal_slope;inputCal_offset;","",0)
	return out
end


//functions to read from the teensy
function/WAVE teensyCal_getReadSet(comStr,[outRef])
	String comStr
	String outRef	//from command line, can copy into a real wave
	
	if (strlen(comStr) < 1)
		comStr = ks_teensyCom
	endif
	
	Variable i
	for (i=0;i<k_teensyReadSetsToAvg;i++)
		WAVE/I currReads = teensyCal_getReads(comStr)
		if (i==0)
			duplicate/o/free/i currReads,out
		else
			concatenate/np=0 {currReads},out
		endif
	endfor
	
	if ( PAramISDefault(outRef) || (strlen(outRef) < 1) )
		return out
	endif
	
	duplicate/o out,$outRef
end

function/WAVE teensyCal_getReads(comStr)
	String comStr
	
	if (strlen(comStr) < 1)
		comStr = ks_teensyCom
	endif
	
	VDT2/P=$comStr killio	//delete and previous serial i/o
	
	make/o/d/n=(k_floatsPerStandardDataTransfer) sendWv; sendWv[0,1] = nan; sendWv[2] = 4; sendWv[3,] = nan;
	int V_VDT = teensy_sendBinary(sendWv);
	
	if (!V_VDT)		//failed
		print "teensyCal_getReads() failed to send command for reads"
		make/o/free/i out = {-1}		//teensy cant have negative values, so this will indicate an error
		return out
	endif
	
	//wait for a return from the teensy over serial i/o
	WAVE readWv = teensy_readOneFloatSetDuringExecution(untilTicks = k_teensyReturnTimeOutSecs*60,timeOutMsg="teensyCal_getReads() unexpectedly failed to get reads")
	redimension/i readWv
	return readWv
end

function teensyCal_setRunningModeOffDuringExecution(comStr)
	String comStr
	
	if (strlen(comStr) < 1)
		comStr = ks_teensyCom
	endif
	
	VDT2/P=$comStr killio	//delete and previous serial i/o
	
	make/o/d/n=(k_floatsPerStandardDataTransfer) sendWv; sendWv[0] = nan; sendWv[1,8] = 0; sendWv[9,] = nan;
	int V_VDT = teensy_sendBinary(sendWv);
	if (!V_VDT)		//failed
		print "teensyCal_getReads() failed to send command for reads"
		make/o/free/i out = {-1}		//teensy cant have negative values, so this will indicate an error
		return 0
	endif
	
	//wait for a return from the teensy over serial i/o
	WAVE readWv = teensy_readOneFloatSetDuringExecution(untilTicks = k_teensyReturnTimeOutSecs*60,timeOutMsg="teensyCal_getReads() unexpectedly failed to get reads")
	return 1	
end


function/WAVE teensyCal_outputCal(comStr,statsRef,portIsConnected)
	STring statsRef
	int portIsConnected
	String comStr
	
	if (strlen(comStr) < 1)
		comstr = ks_teensycom
	endif
	
	STring dispWinName = statsRef + "_outputCalWin"
	
	Variable vMin = 0,vMax=4095
	Variable vFitStart = 30,vFitEnd=4065
	Variable numAdditionalLevels=14
	
	Variable numLevels = 2+ numAdditionalLevels		//vMin and vMax plus any additional
	
	if (!portIsConnected)
		vdtoperationsport2 $comstr;VDT2/P=$comstr baud=k_comBaud;		//connect to teensy
	endif
	
	int off = teensyCal_setRunningModeOffDuringExecution(comStr)
	if (!off)
		print "teensyCal_inputCal() failed to set teensy running mode to off! calibration may fail / look like a flat relationship. May need to reload sketch onto teensy"
	endif

	//numRows == numLevels; numCols == numWaveStats; numLayers == num statTypes "teensyOutputVoltage;scaledOutputVoltage;equivCurrent;"
	String statTypeDescs="teensyOutputVoltage;scaledOutputVoltage;equivCurrent;"
	int numStatTypes = itemsinlist(statTypeDescs)
	make/o/d/n=(4)/free/W wstest; wavestats/q/w wstest;WAVE M_wavestats;Variable numStats = dimsize(M_wavestats,0)	//just find out how many rows there are in wavestats output
	make/o/d/n=(numLevels,numStats,numStatTypes) $statsRef/wave=stats; stats = nan
	setscale/I x,vMin,vMax,stats		//assign level scaling (and let Igor calculate intermediate levels)
	copydimlabels/rows=1 M_wavestats,$statsRef
	//dl_lblsToLbls("M_wavestats",0,0,inf,statsRef,1,0,"",0)		//assign wave stats labels to columns	
	redimension/n=(-1,numStats+2,-1) stats;		//make a place to store exact cmdVal and what is reported as output just in case
	stats = nan
	dl_assignLblsFromList(stats,1,numStats,"cmdVal;returnedVal;","",0)
	numStats+=2;
	dl_assignLblsFromList(stats,2,0,statTypeDescs,"",0)		//assign layer labels -- order must stay or else update fit code below
	
	//make waves to store raw reads from the command and input copies going into the dac,setup reading into them
	Variable avgPnts = k_dacAvgLenSecs * k_dacSampleRate
	make/o/d/n=(avgPnts) teensyOutputVoltage,scaledOutputVoltage
	setscale/p x,0,1/k_dacSampleRate,"s",teensyOutputVoltage,scaledOutputVoltage
	Variable ok = fDAQmx_ScanStop(ks_dacName)		//assure not already scanning	

	//run the test
	int i;Double level,rangeMinV,rangeMaxV
	make/o/free/n=(numLevels+1,10) daqErrors = nan	//error tracing
	String winN
	for (i=0;i<numLevels;i+=1)
		level = round(pnt2x(stats,i))		//make it an integer
		level = max(level,0)		//keep within limits
		level = min(level,4095)
		stats[i][%cmdVal][] = level
		WAVE teensyReturn = teensyCal_writeOutputCalVal(level)
		stats[i][%returnedVal][] = teensyReturn[2]
		doupdate;sleep/s k_waitAfterNewLevelSecs;doupdate;
		
		daqmx_scan/DEV=ks_dacName/AVE=(k_dacAvgNum)/STRT=0/BKG WAVES=("teensyOutputVoltage,"+num2str(k_teensyOutputCopyChanNum)+";scaledOutputVoltage,"+num2str(k_teensyScaledOutputCopyChanNum)+";")
		daqErrors[i][1]  = fdaqmx_scanstart(ks_dacName,0)		//start dac reading in background, fills cmdCopy and inputCopy
			//get and store dac reads
		daqErrors[i][2]  = fDAQmx_ScanWait(ks_dacName)	//wait til cmdCopy and inputCopy have been filled
		wavestats/q/w teensyOutputVoltage; stats[i][0,numStats-3][%teensyOutputVoltage]=M_wavestats[q]
		wavestats/q/w scaledOutputVoltage;stats[i][0,numStats-3][%scaledOutputVoltage]=M_wavestats[q]
		daqErrors[i][3]  = fDAQmx_ScanStop(ks_dacName)
			//scaled stats
		stats[i][%avg][%equivCurrent]=stats[i][%avg][%scaledOutputVoltage]*output_injected_pA_per_commanded_V
		stats[i][%sdev][%equivCurrent]=stats[i][%sdev][%scaledOutputVoltage]*output_injected_pA_per_commanded_V
		stats[i][%sem][%equivCurrent]=stats[i][%sem][%scaledOutputVoltage]*output_injected_pA_per_commanded_V
		
		//output
		if (i==0)
			killwindow/Z $dispWinName
			display/k=1/N=$dispWinName stats[][%avg][%equivCurrent]/tn=equivCurrent vs stats[][%cmdVal][0]
			winN=s_name  
			appendtograph/w=$winN/l=L_input stats[][%avg][%teensyOutputVoltage]/tn=teensyOutputVoltage vs stats[][%cmdVal][0]
			appendtograph/w=$winN/l=left_sdev/b=bottom_sdev stats[][%sdev][%equivCurrent]/tn=equivCurrent_sdev vs stats[][%cmdVal][0]
			appendtograph/w=$winN/l=L_input_sdev/b=bottom_sdev stats[][%sdev][%teensyOutputVoltage]/tn=teensyOutputVoltage_sdev vs stats[][%cmdVal][0]
			
			errorbars/w=$winN/T=0/L=0.6/RGB=(0,0,0) equivCurrent,y,wave=(stats[][%sdev][%equivCurrent],stats[][%sdev][%equivCurrent])
			errorbars/w=$winN/T=0/L=0.6/RGB=(0,0,0) teensyOutputVoltage,y,wave=(stats[][%sdev][%teensyOutputVoltage],stats[][%sdev][%teensyOutputVoltage])
			modifygraph/W=$winN axisenab(bottom)={0,0.4},axisenab(bottom_sdev)={0.61,1}
			modifygraph/w=$winN freepos=0,lblpos=52,axisenab(left)={0.55,1},axisenab(l_input)={0,0.45}
			modifygraph/w=$winN freepos=0,lblpos=52,axisenab(left_sdev)={0.62,1},axisenab(l_input_sdev)={0,0.38},lblPos(left)=57
			Label/w=$winN left "Scaled\routput (pA)";Label/w=$winN bottom "Teensy Cmd (0-4095)";Label/w=$winN L_input "Unscaled\rTeensy Output (V)"
			Label/w=$winN left_sdev "SDEV (pA)\\U";Label/w=$winN bottom_sdev "Teensy Cmd (0-4095)";Label/w=$winN L_input_sdev "SDEV (mV)\\u#2";ModifyGraph/w=$winN prescaleExp(L_input_sdev)=3
			ModifyGraph/w=$winN freePos(L_input_sdev)={0,bottom_sdev},freePos(left_sdev)={0,bottom_sdev}
			ModifyGraph/w=$winN  mode(equivCurrent)=4,marker(equivCurrent)=19,msize(equivCurrent)=1,mode(teensyOutputVoltage)=4,marker(teensyOutputVoltage)=19,msize(teensyOutputVoltage)=1
		endif 
		doupdate;
		Print "teensyCal_outputCal() completed level #=",i,"level=",level
	endfor
	
	WAVE teensyReturn = teensyCal_writeOutputCalVal(-1,noRounding=1)		//pass an out of bounds number to break write mode	
	
	if (!portIsConnected)
		vdtcloseport2 $comstr	
	endif
	
	//fit line to input-output relation
	Variable avgCol = finddimlabel(stats,1,"avg")
	Variable levelsCol = finddimlabel(stats,1,"cmdVal")
	Variable equivCurrentLayer = finddimlabel(stats,2,"equivCurrent")
	Variable cmdValLayer = finddimlabel(stats,2,"cmdVal")
	STring coefsSafeRef = statsRef +"_coefs"
	make/o/d/n=(2) $coefsSafeRef/wave=coefs
	curvefit/n line, kwcwave=coefs, stats[][avgCol][equivCurrentLayer]/x=stats[][levelsCol][cmdValLayer]/d //vs stats(vFitStart,vFitEnd)[%avg][%teensyReads]
	ModifyGraph/w=$winN rgb($("fit_"+statsRef))=(1,4,52428)

	Double slope = coefs[1],offset=coefs[0]
	print "convert from current to a teensy write val with: (teensyWriteVal)=((currentVal in pA)-(offset))/(slope); (teensyWriteVal)=((currentVal in pA)-("+num2str(offset)+"))/("+num2str(slope)+")"

	make/o/d/free out = {slope,offset}
	dl_assignlblsfromlist(out,0,0,"outputCal_slope;outputCal_offset;","",0)
	return out
end	

function/WAVE teensyCal_writeOutputCalVal(val,[noRounding])
	int val
	int noRounding	//pass above zero to suppress rounding
	
	
	if (ParamIsDefault(noRounding) || !noRounding)
		val = max(val,0)
		val = min(val,4095)
	endif
	

	make/o/d/n=(k_floatsPerStandardDataTransfer) sendWv; sendWv[0,1] = nan; sendWv[2] = 5; sendWv[3] = val; sendWv[4,] = nan;
	int V_VDT =  teensy_sendBinary(sendWv);
	if (!V_VDT)		//failed
		print "teensyCal_writeOutputCalVal() failed to send command for value=",val,"aborting"
		make/o/free/i/n=(k_floatsPerStandardDataTransfer) out = nan		//teensy cant have negative values, so this will indicate an error
		return out
	endif
	WAVE returnWv = teensy_readOneFloatSetDuringExecution(untilTicks = k_teensyReturnTimeOutSecs*60,timeOutMsg="teensyCal_writeOutputCalVal() unexpectedly failed to get response")
	print "sendWv",sendWv,"returnWv",returnWv
	return returnWv
end
	
function teensyCal_setFollowMode(on)
	int on 		//1 for on, zero for off
	
	make/o/d/n=(k_floatsPerStandardDataTransfer) sendWv; sendWv[0,1] = nan; sendWv[2] = 6;
	sendWv[3] = on ? 1 : -1		//send 1 to set to follow, -1 to turn off
	sendWv[4,] = nan
	teensy_sendBinary(sendWv);	//teensy does not respond in either case
end

//not used in GUI, must run from command line -- may be out of date!
//function teensyCal_follow(comStr,statsRef,sinFreq,sinMin,sinMax)
//	String comStr
//	String statsRef
//	Variable sinFreq		//sinusoid frequency in Hz
//	Double sinMin,sinMax	//minimum value of sine wave in V (-10,10 is max range; teensy is good at following -8 to 8)
//	
//	if (strlen(comStr) < 1)
//		comStr = ks_teensyCom
//	endif
//	
//	vdtoperationsport2 $comStr;VDT2/P=$comStr baud=k_comBaud;		//connect to teensy
//	Variable teensyInFollowMode = teensyCal_setFollowMode(1)				//put it in follow mode, hopefully
//	if (!teensyInFollowMode)
//		print "teensyCal_follow() teensy failed to enter follow mode, aborting"
//		return 0
//	endif
//	
//	//nidaq command parameters -- will just make one second of stimulus, but repeat it over and over for as many repeats as we want (set by numSecs)
//	Variable sampleFreq = 100000	//e.g., 100,000 Hz (100 kHz) sample freq.. listed limit is 250 kHz, but in Igor the nidaq driver gives back an error at 200 kHz, allows 100 kHz. havent tested others
//	Variable samplePeriod = 1/sampleFreq
//	Variable numSecs = 5
//	
//	Variable outputLengthSamples = numSecs * sampleFreq
//	
//	//build sine wave
//	Double sinMid = (sinMin + sinMax)/2
//	Double sinAmp = (sinMax - sinMin)/2
//		
//	make/o/d/n=(sampleFreq) sinTest
//	setscale/p x,0,samplePeriod,"s",sinTest
//	sinTest = sinMid + sinAmp*sin(2*pi*sinFreq*x)
//	
//	//set up to run this on DAC command pin, but dont start yet
//	Variable ok = fdaqmx_writechan(ks_dacName,k_teensyCmdChanNum,-8,-10,10)	//start off commanding a negative voltage as output, so that the sine wave (which starts half way between vMin and vMax is clear (hopefully)	
//	daqmx_waveformgen/dev=ks_dacName/bkg/strt=0 "sinTest, "+num2str(k_teensyCmdChanNum)+";"
//	
//	//set up to record inputs to and outputs from teensy as captured by the nidaq board, also setup display
//	String trigStr = "/" + ks_dacName + "/ao/starttrigger"		//passing this below tells nidaq board to record when waveform starts
//	
//	String recordingWvDescs = "cmdCopy;in;out;scaledOut;"	
//	WAVE/T recordingWvs = listToTextWave(recordingWvDescs,";")
//	dl_assignLblsFromList(recordingWvs,0,0,recordingWvDescs,"",0)
//	recordingWvs = statsRef +"_"+recordingWvs
//	
//	String winN = statsRef+"_win",desc,axisN
//	variable i,numRecs = dimsize(recordingWvs,0);string recwv
//	
//	//make recording waves and display
//	killwindow/Z $winN; display/k=1/n=$winN;winN = s_name
//	for (i=0;i<numRecs;i+=1)
//		desc = getdimlabel(recordingWvs,0,i)
//		axisN = "L_"+desc
//		recwv = recordingWvs[i]
//		make/o/d/n=(outputLengthSamples) $recwv
//		setscale/p x,0,samplePeriod,"s",$recwv
//		
//		appendtograph/l=$axisN $recwv/tn=$desc
//	endfor
//	doupdate;disp_arrayAxes(winN,"L*",0.04,"",rev=1)
//	modifygraph/w=$winN live=1		//live mode might be faster
//	setaxis/w=$winN L_cmdCopy,-10,10
//	setaxis/w=$winN L_in,-0.2,3.5
//	setaxis/w=$winN L_out,-0.2,3.5
//	setaxis/w=$winN L_scaledOut,-10,10
//	modifygraph/w=$winN freepos=0,lblpos=50,lsize(cmdCopy)=2,rgb(cmdCopy)=(0,0,0),rgb(in)=(26214,26214,26214),rgb(scaledOut)=(26214,0,0)
//
//	doupdate;
//	
//	String scanWvStr=recordingWvs[%cmdCopy]+","+num2str(k_teensyCmdCopyChanNum)+";"+recordingWvs[%in]+","+num2str(k_teensyInputCopyChanNum)+";"
//	scanWvStr += recordingWvs[%out]+","+num2str(k_teensyOutputCopyChanNum)+";"+recordingWvs[%scaledOut]+","+num2str(k_teensyScaledOutputCopyChanNum)+";"
//	Variable ok1 = fDAQmx_ScanStop(ks_dacName)		//assure not already scanning
//	daqmx_scan/DEV=ks_dacName/STRT=1/BKG/TRIG=(trigStr) WAVES=(scanWvStr)		//start scanning, but due to trigger actually waits for waveform gen to start
//	//print fDAQmx_ErrorString()
//	
//	//start command, which also starts acquisition due to /TRIG=(trigStr)
//	Variable ok2 = fdaqmx_waveformstart(ks_dacName,numSecs)
//	
//	Variable ok3 = fDAQmx_ScanWait(ks_dacName)	//wait til cmdCopy and "in" have been filled
//	
//	//turn teensy off follow mode once complete
//	Variable teensyOutOfFollowMode = teensyCal_setFollowMode(0)
//	
//	vdtcloseport2 $comStr	
//	
//	setwindow $winN, hook(winHook_killWaves)=winHook_killWaves
//end


#endif	//end #if (exists("fdaqmx_writechan")) [automated calibration]


//HELPER FUNCTIONs

function teensy_bytesAvailable(comStr)
	String comStr
	if (strlen(comStr) < 1)
		comstr = ks_teensycom
	endif
	
	vdt2/P=$comStr
	
	vdtgetstatus2 0,0,0		//check for input on the serial buffer
	return V_VDT
end

//Active electrode compensation kernel calculation:
//Has Teensy run noise nAvg number of times, reads each response and computes an overall kernel (electrode+membrane) for it
//then computers the average overall kernel and uses the algorithm of Brette to infer the electrode and membrane kernels
//sends the electrode kernel back to the teensy so the teensy can use it to deconvolve a more accurate membrane voltage reading
//the full kernel, electrode kernel, and membrane kernels are stored in the Package folder for the gui (root:Packages:<panelN>)
//assumes teensy gui is working properly
static constant k_reportFrequency_steps = 15		//how often to print what's going on with the recording/transfer
//these should agree with their counterparts in injectNoise.ino
static constant k_numSteps = 10000
static constant k_serialLimitBytes = 64;
static constant k_aec_tailStartPnt = 32//31//15//7
static constant k_aec_fitEndX = inf //0.25// inf //0.25		//seconds to fit; to fit entire kernel, use inf
static constant k_noiseRun_typeNum = 1		//must match special case type for running noise in sketch
function/S teensy_gui_aec(panelN,nAvg,noiseMin_pA,noiseMax_pA,postCmd_pA,stepMicros)
	String panelN
	Variable noiseMin_pA,noiseMax_pA		//min and max of noise in pA. randomly distributed
	Variable postCmd_pA	//holding for between trials to average and after all are complete
	Variable nAvg			//how many averages for the kernel
	int stepMicros		//5 or 10 microseconds work well. Really can't go below 5 unless someone finds a way to speed clamp cycles
		
	if (strlen(panelN) < 1)
		panelN = winname(0,64)	//top panel
	endif
	
	String folderPath = "root:Packages:"+panelN
	String comStr = getuserdata(panelN,"","comStr")
		
	make/free/o/n=(k_floatsPerStandardDataTransfer)/free settingsWv;	
	//for serial handling in teensy, points 0 and 1 nan, two specifies this is a noise transfer
	settingsWv[0,1] = nan
	settingsWv[2] = k_noiseRun_typeNum
	//settingsWv[3] = seed;  //seed now set in loop so we can average white noise generated with different seeds
	settingsWv[4] = noiseMin_pA;  //set min
	settingsWv[5] = noiseMax_pA;   //set max
	settingsWv[6] = postCmd_pA;		//set cmd in between and after (if clamping, will quickly be overwritten after all rounds completed)
	settingsWv[7] = stepMicros;	//target step microseconds
	
	string stepMicrosStr; sprintf stepMicrosStr,"%d",stepMicros
	setwindow $panelN userdata(aec_stepMicros)=stepMicrosStr
	
	string infoStr = "";
	make/o/free/n=(1)/d  currentTemp,voltageTemp,ccTemp_td	,stimAutocorrTemp_fd	//assigned after first iteration, need to be declared for compilation
	make/o/c/free/n=(1) ccTemp_fd //assigned after first iteration, need to be declared for compilation

	Variable respFloat
	Double meanVal
	int crossCorrDur_micros	
	int i,endIteration = nAvg+1		//go one extra in order to cross correlate last one
	for (i=0;i<endIteration;i++)
		
		if (i < nAvg)		//if we have collected all data, don't send again
			//send settings to kick it off. First and all responses will be readings. 
			settingsWv[3] = i+12;		//set seed .. 6 is just a random pick
			teensy_sendOneSetOfFloats(panelN,settingsWv,1,1,noReceiveBg=1)
		endif
		
		if (i > 0)		//while the noise is running, can calculate cross corr here
			[ccTemp_fd,stimAutocorrTemp_fd]=simpleCrossCorrAndStimPower(currentTemp,voltageTemp)
			
			if (i==0)
				duplicate/o/free ccTemp_fd,cc_fd
				duplicate/o/free stimAutocorrTemp_fd,stimAc_fd
			else
				concatenate/np=1/free {ccTemp_fd},cc_fd
				concatenate/np=1/free {stimAutocorrTemp_fd},stimAc_fd
			endif
		
			if (i>=navg)		//time to stop
				break
			endif
		endif
		
		
		//wait for response and then read it
		WAVE responses = teensy_readDuringExecution(comStr,nan)
		int totalData = responses[0]
		int badStepCount = responses[1]
		int worstStepOvershoot = responses[2]
		int numSteps = floor( (totalData-3)/2)
		duplicate/o/r=[3,3+numSteps-1]/free responses,currentTemp
		duplicate/o/r=[3+numSteps,3+2*numSteps-1]/free responses,voltageTemp
		
		//scale to real values //teensy_gui_bit2vmOrVm2bit teensy_gui_current2bitOrBit2Current
		currentTemp = teensy_gui_current2bitOrBit2Current(panelN,currentTemp,1)
		voltageTemp = teensy_gui_bit2vmOrVm2bit(panelN,voltageTemp,0)
		meanval = mean(currentTemp); matrixop/o currentTemp = currentTemp - meanVal
		meanval = mean(voltageTemp); matrixop/o voltageTemp = voltageTemp - meanVal
	
		if (i==0)
			duplicate/o/free currentTemp,outCurrent
			duplicate/o/free voltageTemp,outVoltage
		else
			concatenate/np=1 {currentTemp},outCurrent
			concatenate/np=1 {voltageTemp},outVoltage
		endif
	
		infoStr+= "numSteps:"+num2str(badStepCount)+";worstStepOvershoot:"+num2str(worstStepOvershoot)+";numSteps:"+num2str(numSteps)+";crossCorrDur_micros:"+num2str(crossCorrDur_micros)+";\r"
		vdt2/p=$ks_teensycom killio //the count is imperfect because some data is often remaining in queue
	endfor
	
	//calc filters and average...
	make/o/d/n=(1) $(folderPath+":aec_fullKernel")/wave=aec_fullKernel
	matrixop/o/c cc_fd_avg = sumRows(cc_fd)/numcols(cc_fd)
	matrixop/o/c stimAc_fd_avg = sumRows(stimAc_fd)/numcols(stimAc_fd)	//imag should all be zero actually so could ignore it
	matrixop/o/c linearEst_fd = cc_fd_avg / stimAc_fd_avg
	ifft/dest=aec_fullKernel linearEst_fd 
	reverse/p aec_fullKernel		//make filter forward-going, as expected downstream
	
	//matrixop/o aec_fullKernel = sumRows(cc_td)/numcols(cc_td)		//calculate average, for more detail use: //wave_colStats(cc_td,0,inf,0,inf,out_filter)
	setscale/p x,0,stepMicros*10^-6,"s",aec_fullKernel
	//Double baselineVal = min(aec_fullKernel[0],aec_fullKernel[1])		//deals with offsets from practical experience so far
	//aec_fullKernel -= baselineVal		//baseline subtract
	
	teensy_aecCalc(panelN,k_aec_fitEndX,1,1)   //decomposes full kernel into electrode and membrane kernels, stores them
																		  //in panel Package folder as aec_membraneKernel and aec_electrodeKernel
	note/nocr aec_fullKernel,infoStr
	print "teensy_gui_runNoise()",infoStr
	
	teensy_gui_sendSettings(panelN,1)		//I dont know why, but sending a settings update helps if the user is going to run this twice in a row
														//running it twice in a row is likely (e.g., if tweaking a setting like min and max current
														
	return getwavesdatafolder(aec_fullKernel,2) //return wave name including full path
end

function/WAVE teensy_readDuringExecution(comStr,num)		//for use with teensy code sendFloat or sendFloats
	String comStr
	variable num		//if length is being sent by teensy (must be first position), then pass nan
	
	if (strlen(comStr) < 1)
		comstr = ks_teensycom
	endif
	
	int dataCount = 0
	Variable respFloat
	do
		if (teensy_bytesAvailable(ks_teensyCom) < 4)	//read at least one float at a time
			continue	//wait for data --unclear to me exactly how usb serial buffering will handle the possible overload from teensy
		endif
		VDTReadBinary2/B/O=(k_backgroundWaitTimeLimit_ticks)/Q/TYPE=(2) respFloat		
		
		if (dataCount == 0)
			if (numtype(num) > 0)
				num = respFloat
			endif
			make/o/n=(num)/free out
		endif	
		out[dataCount]=respFloat
		dataCount++
		
	while (dataCount < num)
	
	return out
end	

//meant to be extremely low level -- com port must be set higher in the call stack
function/WAVE teensy_readOneFloatSetDuringExecution([respWv,untilTicks,timeOutMsg])
	WAVE respWv		//pass a pre-existing wave which must be of length k_floatsPerStandardDataTransfer
	int untilTicks		//optionally pass a set number of ticks before timeout. in this case, assumes using standard teensy comStr
	String timeOutMsg	//for untilTicks only, optionally pass a message to print in case of time out
	
	if (ParamIsDefault(respWv))
		make/o/d/n=(k_floatsPerStandardDataTransfer)/free out
	else
		WAVE out = respWv
	endif

	if (ParamIsDefault(untilTicks) || (numtype(untilTicks) != 0) )
		VDTReadBinaryWave2/B/O=(k_backgroundWaitTimeLimit_ticks)/Q/TYPE=(2) out
		return out
	endif
	
	int endTicks = ticks + untilTicks
	do
		if (teensy_bytesAvailable("") >= (k_floatsPerStandardDataTransfer*4) )
			VDTReadBinaryWave2/B/O=(k_backgroundWaitTimeLimit_ticks)/Q/TYPE=(2) out
			return out			
		endif
	while (ticks <= endTicks) 
	
	out = nan		//indicate failure with all nans
	if (!paramIsDefault(timeOutMsg))
		print timeOutMsg
	endif
	return out		
end


static constant k_aec_ignorePnts = 0  //how many points to set to zero at the beginning of the filter wave -- 1 is recommended. zero doesnt change much, but it's unclear how to use that instantaneous point for active electrode compenation
static constant k_teensy_aecOptimzer_maxIters = 1000
function teensy_aecCalc(panelN,fitEndX,storeErrors,storeFitData)
	String panelN
	Variable fitEndX,storeErrors		//if store errors, the error on each optimization iteration is stored in a global wave called teensy_aecOptimzer_errors
	Variable storeFitData	//if storeFitData, the fit waves from each operation are saved into teensy_aecOptimzer_K_all,teensy_aecOptimzer_Y_iters

	if (strlen(panelN) < 1)
		panelN = winname(0,64)	//top panel
	endif
		
	String folderPath = "root:Packages:"+panelN
	WAVE aec_fullKernel = $(folderPath+":aec_fullKernel")		//must be precalculated and stored here (i.e., by teensy_gui_aec)
	
	if (numtype(fitEndX))
		fitEndX = pnt2x(aec_fullKernel,dimsize(aec_fullKernel,0)-1)
	endif
	print "fitEndX",fitEndX
	Variable fitEndP = x2pnt(aec_fullKernel,fitEndX)
	Variable fitPnts = fitEndP + 1
	Variable tailStartX = pnt2x(aec_fullKernel,k_aec_tailStartPnt)
	Variable ignoreRangeEndX = pnt2x(aec_fullKernel,k_aec_ignorePnts)
	print "fitEndP",fitEndP,"fitPnts",fitPnts
	
	//fit exponential y = K0+K1*exp(-(x-x0)/K2). we will force K0 = 0 and x0 will be equal to zero
	make/o/d/free/n=(3) coefs
	coefs[0] = 0		//set y0 to initialize at zero
	//curvefit/q/w=2 exp_xoffset, aec_fullKernel[k_aec_tailStartPnt,fitEndP]		//hold y0 contant with /h="100"
	curvefit/q/w=2/h="100" exp_xoffset,kwCWave=coefs aec_fullKernel[k_aec_tailStartPnt,fitEndP]		//hold y0 contant with /h="100"
	//WAVE w_coef	
	Double memAmp = coefs[1] //W_coef[1]//coefs[1] 
	Double memTau = coefs[2] //W_coef[2] //coefs[2]
	
	//calculate the tail fit  -- make this a global wave, so it is accessible to the optimize function
	make/o/d/n=(fitPnts) $(folderPath+":aec_fullKernel_asMemTauFit")/wave=teensy_aecOptimzer_K; 
	setscale/p x,dimoffset(aec_fullKernel,0),dimdelta(aec_fullKernel,0),waveunits(aec_fullKernel,0),teensy_aecOptimzer_K
	teensy_aecOptimzer_K=	memAmp*exp(-x/memTau)		//W_coef[0]+memAmp*exp(-x/memTau)		//use at first to sum the first few poins of the fit to compute elR below, then used for optimization
	
	//estimate membrane and electrode resistances -- their ratio is the parameter to optimize with (initGuess)
	Double memR = memAmp*memTau //memR is integral of membrane impulse response // - tailFit[0] - tailFit[1] // - memAmp*exp(-pnt2x(aec_fullKernel,0)/memTau) - memAmp*exp(-pnt2x(aec_fullKernel,1)/memTau)		//dont understand why these are necessary to estimate rm
	Double elR = (sum(aec_fullKernel,ignoreRangeEndX,tailStartX) - sum(teensy_aecOptimzer_K,ignoreRangeEndX,tailStartX))*dimdelta(aec_fullKernel,0)		//re is integral of electrode impulse response (which is estimated by subtracting integral of mem impulse)
	Double initGuess = memR/elR
	
	//use fit for optimization: set the early pnts equal to the region assumed to represent the electrode kernel
	if (k_aec_ignorePnts >= 1)
		teensy_aecOptimzer_K[0,k_aec_ignorePnts-1]=0		//set ignore points to zero
	endif
	teensy_aecOptimzer_K[k_aec_ignorePnts,k_aec_tailStartPnt-1]=aec_fullKernel[p]		//set preTail pnts equal to kernal, rest are equal to membrane fit
	
	//now optimize to match membrane fit
		//fit parameters and constants (stored in pwave)
	Double lowBracket = 0.5*initGuess
	Double highBracket = 2*initGuess
	Double tol = initGuess*0.0001		//range finder: get minimum within 0.01% of the size of the initial guess
	Variable dt = dimdelta(aec_fullKernel,0)
	STring pwaveLbls = "memTau;tailStartP;iter;storeErrors;storeFitData;"
	make/o/d/free/n=(itemsinlist(pwaveLbls)) pwave
	dl_assignlblsfromlist(pwave,0,0,pwaveLbls,"",0)
	pwave[%memTau]=memTau
	pwave[%tailStartP]=k_aec_tailStartPnt
	pwave[%iter]=0
	pwave[%storeErrors]=storeErrors
	pwave[%storeFitData]=storeFitData
	note/K/nocr pwave,panelN		//optimizer retrieves panelN from this wave note
	
		//waves needed 
	duplicate/o teensy_aecOptimzer_K,$(folderPath+":aec_membraneKernel")/wave=teensy_aecOptimzer_Y,$(folderPath+":aec_electrodeKernel")/wave=teensy_aecOptimzer_elK	
	
		//extra waves needed in case tracking fit details
	if (storeErrors)
		make/o/d/n=(k_teensy_aecOptimzer_maxIters,2) $(folderPath+":aec_optimizerErrors_iters")/wave=teensy_aecOptimzer_errors
		teensy_aecOptimzer_errors = nan
		dl_assignlblsfromlist(teensy_aecOptimzer_errors,1,0,"x;error;","",0)
		print "startig fit memTau",memTau,"memR",memR,"elR",elR,"init guess",initGuess,"teensy_aecOptimzer_errors",getwavesdatafolder(teensy_aecOptimzer_errors,2)
	else
		print "startig fit memTau",memTau,"memR",memR,"elR",elR,"init guess",initGuess
	endif
	
	if (storeFitData)
		duplicate/o teensy_aecOptimzer_Y,$(folderPath+":aec_membraneKernel_iters")/wave=teensy_aecOptimzer_Y_iters	//store Y for all iterations
		redimension/n=(-1,k_teensy_aecOptimzer_maxIters) teensy_aecOptimzer_Y_iters
		teensy_aecOptimzer_Y_iters = nan
	endif
	
	//run optimization
	optimize/L=(lowBracket)/H=(highBracket)/t=(tol)/I=(k_teensy_aecOptimzer_maxIters)/Q teensy_aecOptimzer, pwave
	if (numtype(V_minloc) > 0)
		print "optimzation failed!!!, V_minloc",V_minloc,"init guess",initGuess
	else
		print "optimzation complete, V_minloc",V_minloc,"init guess",initGuess
	endif
	
	//delete data from iterations not used, if needed
	if (storeErrors)
		redimension/n=(pwave[%iter]-1,-1) teensy_aecOptimzer_errors
	endif
	if (storeFitData)
		redimension/n=(-1,pwave[%iter]-1) teensy_aecOptimzer_Y_iters
	endif
end

//expects globals in current dat folder: teensy_aecOptimzer_Y,teensy_aecOptimzer_K teensy_aecOptimzer_elK
Function teensy_aecOptimzer(w,x0)
	Wave w //constats: from pwaveLbls = "memTau;tailStartP;storeErrors;iter;"
	Variable x0  //x paramete to minimize: memR / elR ratio
	
	String panelN = note(w)		//panelN is stored here by calling function (handled by teensy_aecCalc)
	String folderPath = "root:Packages:"+panelN
	
	//these must be instantiated at proper length before calling this function (handled by teensy_aecCalc)
	WAVE teensy_aecOptimzer_K = $(folderPath+":aec_fullKernel_asMemTauFit")
	WAVE teensy_aecOptimzer_Y = $(folderPath+":aec_membraneKernel")
	WAVE teensy_aecOptimzer_elK = $(folderPath+":aec_electrodeKernel")
	
	Variable dt = dimdelta(teensy_aecOptimzer_K,0)
	Variable tailStartP = w[%tailStartP]
	Variable tailEndP = dimsize(teensy_aecOptimzer_K,0)-1
	
	Double alpha = x0*dt/w[%memTau]			//is dt needed if memTau is scaled?
	Double lambda = exp(-dt/w[%memTau])
	//iterative calculation of convolution result
	//compute first point
	if (k_aec_ignorePnts < 1)
		teensy_aecOptimzer_Y[0]=alpha*teensy_aecOptimzer_K[0]/(alpha+1)
	else
		teensy_aecOptimzer_Y[0]=0 				//k[0] is zero in this case, so the first point will be zero
	endif
	//iteratively calculate the rest
	teensy_aecOptimzer_Y[1,]=(alpha*teensy_aecOptimzer_K[p] + lambda*teensy_aecOptimzer_Y[p-1])/(alpha+1)	//from recursive equation, middle of page 16 of supplement of Brette
	teensy_aecOptimzer_elK = teensy_aecOptimzer_K - teensy_aecOptimzer_Y
	matrixop/o errWv = subrange(teensy_aecOptimzer_elK,tailStartP,tailEndP,0,0).subrange(teensy_aecOptimzer_elK,tailStartP,tailEndP,0,0)	//compute the inner product
	
	print "iteration",w[%iter],"x0",x0,"err",errwv[0],"alpha",alpha,"lambda",lambda,"coef0 (alpha/(alpha+1))",(alpha/(alpha+1)),"coef1 (lambda/(alpha+1))",(lambda/(alpha+1))
	
	if (w[%storeErrors])		//store error
		WAVE teensy_aecOptimzer_errors = $(folderPath+":aec_optimizerErrors_iters")  //created in calling function
		teensy_aecOptimzer_errors[w[%iter]][%x]=x0
		teensy_aecOptimzer_errors[w[%iter]][%error]=errWv[0]
	endif
	
	if (w[%storeFitData])
		WAVE teensy_aecOptimzer_Y_iters = $(folderPath+":aec_membraneKernel_iters")	//created in calling function
		teensy_aecOptimzer_Y_iters[][w[%iter]] = teensy_aecOptimzer_Y[p]
	endif
	
	w[%iter]+=1

	return errWv[0]		//return function result, the error to be minimized
End

function [WAVE/c out, wave/c temp0_fd_autocorr] simpleCrossCorrAndStimPower(WAVE wv0,WAVE wv1)		//returns result in complex (fd) and time domains (td)
	//calculates the cross correlation of wv0 and wv1 assuming wv1 is linearly related to wv0 (i.e., wv0 was the stimulus)
	//intended for use where an ensemble of stim-response pairs is to be computed this way and averaged
	//and the average is to be normalized by the stimulus power. See Kim and Rieke 2001
	
	fft/dest=temp0_fd/free wv0
	fft/dest=temp1_fd/free wv1
	duplicate/o/c temp0_fd,temp0_fd_autocorr
	temp0_fd_autocorr = temp0_fd * conj(temp0_fd)
	duplicate/o/c/free temp0_fd,out
	out *= conj(temp1_fd)
	return [out, temp0_fd_autocorr]
end

//need to make this a wrapper for a standard sending function
static constant k_sendElectrodeKernelOffsetPnts = 5//offset expected from start pnts (nan values) to beginning of electrode kernel sent to teensy. must match sketch
																	   //should be 4 pnts: 2 nan followed by type num followed by kernel le
static constant k_electrodeKernel_typeNum = 2		//type num for special data transfer case, must match sketch
function teensy_gui_sendElectrodeKernel(panelN,ignoreMicros,[forceConstantKernelVal,forceKernelPnts,noNegativeKernelVals])
	String panelN
	Double forceConstantKernelVal		//optionally pass a value for all kernel pnts (e.g., 0 for debugging)
	int forceKernelPnts
	int noNegativeKernelVals
	int ignoreMicros		//whether to ignore start of filter. 0 micros to use all
	
	if (strlen(panelN) < 1)
		panelN = winname(0,64)	//top panel
	endif
	
	String folderPath = "root:Packages:"+panelN
	WAVE/Z teensy_aecOptimzer_elK = $(folderPath+":aec_electrodeKernel")  //default: use the computed electrode kernel

	if (!waveexists(teensy_aecOptimzer_elK))
		print "teensy_gui_sendElectrodeKernel() teensy_aecOptimzer_elK is not calculated. Calculate AEC kernels first!"
		return 0
	endif
		
	//for sending the kernel, first two points are nan and next point is the length of the kernel
	int electrodeKernelEndP = k_aec_tailStartPnt - 1
	int electrodeKernelLenP = electrodeKernelEndP + 1 		//default
	if (!paramIsdefault(forceKernelPnts) && (numtype(forceKernelPnts) == 0) )
		electrodeKernelLenP = forceKernelPnts
	endif
	int sentWvLenP = electrodeKernelLenP + k_sendElectrodeKernelOffsetPnts 
	make/o/n=(sentWvLenP)/d $(folderPath+":aec_lastKernelSendWv")/wave=aec_lastKernelSendWv
	aec_lastKernelSendWv[0,1] = nan		//teells teensy to expect special case transfer
	aec_lastKernelSendWv[2]= k_electrodeKernel_typeNum
	aec_lastKernelSendWv[3] = electrodeKernelLenP
	aec_lastKernelSendWv[4] = ignoreMicros
		
	if (PAramIsDefault(forceConstantKernelVal) || (numtype(forceConstantKernelVal) > 0) ) //usual case
		aec_lastKernelSendWv[k_sendElectrodeKernelOffsetPnts,] = teensy_aecOptimzer_elK[p-k_sendElectrodeKernelOffsetPnts]		//skip the zeroth (instantaneous) point
	else
		aec_lastKernelSendWv[k_sendElectrodeKernelOffsetPnts,] = forceConstantKernelVal
	endif
	if (!ParamIsDefault(noNegativeKernelVals) && noNegativeKernelVals)
		aec_lastKernelSendWv[k_sendElectrodeKernelOffsetPnts,]=aec_lastKernelSendWv[p]<0 ? 0 : aec_lastKernelSendWv[p]
	endif
	
	print "aec_lastKernelSendWv len",sentWvLenP,"wv=",aec_lastKernelSendWv
	//note that the wave does not need to be of length that is multiple of k_floatsPerStandardDataTransfer (16), any extras are sent as NaN from teensy_gui_sendFloats 
	teensy_gui_sendFloats(panelN,"aec_lastKernelSendWv",0,0)
	
	teensy_gui_sendSettings(panelN,1)		//I dont know why, but sending a settings update helps if the user is going to run this twice in a row
														//running it twice in a row is likely (e.g., if tweaking a setting like min and max current

end

function teensy_gui_getElectrodeKernelIntegral(panelN,cmd_pA)
	String panelN; Variable cmd_pA
	
	if (strlen(panelN) < 1)
		panelN = winname(0,64)	//top panel
	endif
	
	String folderPath = "root:Packages:"+panelN
	WAVE/Z wv = $(folderPath+":aec_electrodeKernel")
	if (!waveexists(wv))
		print "teensy_gui_getElectrodeKernelIntegral() teensy_aecOptimzer_elK is not calculated. Calculate AEC kernels first!"
		return 0
	endif
	
	return area(wv,pnt2x(wv,k_aec_ignorePnts),pnt2x(wv,k_aec_tailStartPnt - 1))//*cmd_pA*10^12


end

//these functions are copied from igorUtilities to allow independent module function
//return the name of all background tasks
static function/s background_getTaskList()
	ctrlnamedbackground _all_,status;
	int i,num = itemsinlist(S_info,"\r"); string currInfo,out=""
	for (i=0;i<num;i++)
		currInfo = stringfromlist(i,s_info,"\r")
		out += stringbykey("name",currInfo)	+";"
	endfor

	return out
end

//assign multiple dimension labels from a String list
static function dl_assignLblsFromList(wv,dim,startIndex,list,appendStr,appendBeforeLblNotAfter[reuseLast])
	WAVE wv		//wave to label
	int dim		//dim to label
	int startIndex	//index to start at in dim to label (end index is based on length of list)
	String list			//list of labels to assign, semi-colon delimited
	String appendStr		//optionally append a string to all labels
	int appendBeforeLblNotAfter		//put appendStr before (1) or after (0) the rest of the label
	int reuseLast		//optionally pass true to coninue using the last in the list until the end of the dimension
	
	int i,num=itemsinlisT(list),maxIndex = dimsize(wv,dim),index=startIndex
	String lb=stringfromlist(0,list)
	for (i=0;index<maxIndex;i++)		//iterate from startIndex to end of dimension
	
		//check for end of list, if so break unless reuseLast is true
		if (i >= num)
			if (ParamIsDefault(reuseLast) || !reuseLast)
				break
			endif
			SetDimLabel dim,index,$lb,wv
		else
		
		//usual case, get label from list and add appendStr
			if (appendBeforeLblNotAfter)
				lb=appendStr + stringfromlist(i,list)
			else
				lb=stringfromlist(i,list) + appendStr
			endif
			
		endif
		
		SetDimLabel dim,index,$lb,wv
		index++	//index is always i+startIndex
	endfor
	
	return i
end

static function disp_arrayAxes(winN,axMatchStr,spaceFrac,orderedList,[rev])
	String winN,axMatchStr
	Variable spaceFrac		//what fraction of total goes to EACH space?
	String orderedList		//bottom to top
	Variable rev		//reverse
	
	if (strlen(winN) < 1)
		winN=winname(0,1)
	endif
	
	if (strlen(axMatchStr) < 1)
	axMatchStr="*"
	endif
	
	String ax,axes
	if (strlen(orderedList)<1)
		axes=listmatch(axislist(winN),axMatchStr)
	else
		axes=orderedList
	endif
	int i,num=itemsinlist(axes),indForCalc
	Variable totalSpace= num>1 ? (num-1)*spaceFrac : 0
	Variable totalFilled=1-totalSpace
	Variable fillPerAx=totalFilled/num
	Variable currStart
	for (i=0;i<num;i+=1)
		if (!paramisDefault(rev))
			indForCalc = rev ? num - i -1 : i
		else
			indForCalc = i
		endif
		ax=stringfromlist(i,axes)
		currStart=indForCalc*fillPerAx+indForCalc*spaceFrac
		modifygraph/w=$winN axisenab($ax)={currStart,currStart+fillPerAx}
	endfor
end

function/S getDateStr(igorDate)
	String igorDate	//pass "" for current (computer) date, pass another date otherwise. Format must be as returned by date()
	
	if (strlen(igorDate) < 1)
		igorDate = date()
	endif
	
	String monthsList = "jan;feb;mar;apr;may;jun;jul;aug;sep;oct;nov;dec;"
	make/o/t/n=(12) monthsStrs = selectstring(p < 9, "", "0") + num2str(p+1)
	String expr="([[:alpha:]]+), ([[:alpha:]]+) ([[:digit:]]+), ([[:digit:]]+)"
	String dayOfWeek, monthName, dayNumStr, yearStr
	SplitString/E=(expr) igorDate, dayOfWeek, monthName, dayNumStr, yearStr
	return yearStr[2,inf] + monthsStrs[whichlistitem(monthName,monthsList,";",0,0)] + dayNumStr
	
end