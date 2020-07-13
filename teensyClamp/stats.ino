//running standard deviation calculation based on https://www.johndcook.com/blog/standard_deviation/
//(in turn based on Donald Knuth’s Art of Computer Programming, Vol 2, page 232, 3rd edition)


struct runningStat {

  //for min and max -- if switching to tracking something other than dt, float might be more appropriate
  unsigned int minVal = 10000;  //might need to change if scale of stat changes; can use inf for float
  unsigned int maxVal = 0;

  //for mean and variance
  uint16_t m_n;
  float m_oldM;
  float m_oldS;
  float m_newM;
  float m_newS; } rs;// S holds variance data, M mean data

//run to initialize or clear
void rs_init() {
  rs.m_n = 0;
}

void rs_push(float x) {
  rs.m_n++;
  if (rs.m_n == 1) {
    rs.m_oldM = x;
    rs.m_newM = x;
    rs.m_oldS = 0.0;
  } else {
    //calculation
    rs.m_newM = rs.m_oldM + (x - rs.m_oldM)/rs.m_n;
    rs.m_newS = rs.m_oldS + (x - rs.m_oldM)*(x - rs.m_newM);

    //next iteration
    rs.m_oldM = rs.m_newM;
    rs.m_oldS = rs.m_newS; 
  }

  unsigned int xInt = (unsigned int)x;
  if (xInt < rs.minVal) {
    rs.minVal = xInt;
  }
  if (xInt > rs.maxVal) {
    rs.maxVal = xInt;
  }  
}

float rs_mean() {
  if (rs.m_n < 1) { //handle not defined for n = 0
    return nanVal;  //original returned 0, but returning nan seems more clear and accurate; nanVal defined in main .ino file
  } else {
    return rs.m_newM;
  }
}

float rs_variance() {
  if (rs.m_n < 2 ) {//handle not defined for n=0,n=1
    return nanVal;  //original returned 0, but returning nan seems more clear and accurate; nanVal defined in main .ino file
  } else {
    return rs.m_newS/(rs.m_n - 1);
  }
}

float rs_standardDeviation() {    //not actually used at present, calculate sqrt on computer in case it's slow
  return sqrt(rs_variance());
}

unsigned int rs_minVal() {
  return rs.minVal;
}

unsigned int rs_maxVal() {
  return rs.maxVal;
}
