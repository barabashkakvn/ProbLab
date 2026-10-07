//+------------------------------------------------------------------+
//|                                                     BridgeEA.mq5 |
//|                              Copyright © 2026, Vladimir Karputov |
//|                      https://www.mql5.com/en/users/barabashkakvn |
//+------------------------------------------------------------------+
#property copyright "Copyright © 2026, Vladimir Karputov"
#property link      "https://www.mql5.com/en/users/barabashkakvn"
#property version   "1.001"
#property description "Reads declarative JSON requests written by Python, calculates"
#property description "the requested indicator buffers and answers with a CSV file."
//+------------------------------------------------------------------+
//| Reads declarative JSON requests written by Python, calculates    |
//| the requested indicator buffers and answers with a CSV file.     |
//|                                                                  |
//| Exchange folder: <terminal common>\Files\Bridge\                 |
//|      request_{id}.json   in                                      |
//|      response_{id}.csv   out                                     |
//| The request file is deleted only after the response has been     |
//| renamed into place - that deletion is the completion signal.     |
//+------------------------------------------------------------------+
#include <JAson.mqh>

//+------------------------------------------------------------------+
//| Reference table structures                                       |
//+------------------------------------------------------------------+
struct SEtalonParam
  {
   string            name;
   string            type;
  };

struct SEtalonBuffer
  {
   string            name;
   int               index;
  };

struct SEtalonIndicator
  {
   string            mql5_call;
   SEtalonParam      params[];
   SEtalonBuffer     buffers[];
  };

//+------------------------------------------------------------------+
//| Request structures                                               |
//+------------------------------------------------------------------+
struct SBuffer
  {
   string            col_name;
   int               index;
  };

struct SIndicator
  {
   string            name;
   string            param_keys[];
   string            param_vals[];
   SBuffer           buffers[];
   int               handle;
  };

struct SRequest
  {
   string            request_id;
   string            symbol;
   string            timeframe;
   string            start_date;
   string            end_date;
   SIndicator        indicators[];
  };

//+------------------------------------------------------------------+
//| Expert advisor globals                                           |
//+------------------------------------------------------------------+
SEtalonIndicator g_etalon[];
string           g_etalon_names[];
bool             g_etalon_loaded = false;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(!LoadEtalon("Bridge\\indicators_etalon.json", g_etalon, g_etalon_names))
     {
      Print("OnInit: cannot load the reference table - the EA will not start");
      return INIT_FAILED;
     }
   EventSetTimer(1);  // poll the folder once a second
   Print("BridgeEA: ready, waiting for requests in Bridge\\");
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() { }  // an expert advisor needs OnTick to attach to a chart

//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer()
  {
   string req_path = FindRequestFile();
   if(req_path == "")
      return;  // nothing to do
   PrintFormat("OnTimer: request found: %s", req_path);
//--- Read and parse
   string json_str;
   if(!ReadFile(req_path, json_str))
     { FileDelete(req_path, FILE_COMMON); return; }
   SRequest req;
   if(!ParseRequest(json_str, req))
     { FileDelete(req_path, FILE_COMMON); return; }
//--- Validate
   if(!ValidateRequest(req, g_etalon, g_etalon_names))
     { FileDelete(req_path, FILE_COMMON); return; }
//--- Create the handles
   if(!CreateAllHandles(req, g_etalon, g_etalon_names))
     { ReleaseHandles(req); FileDelete(req_path, FILE_COMMON); return; }
//--- Write the CSV
   string response_path = "Bridge\\response_" + req.request_id + ".csv";
   bool ok = WriteCSV(req, response_path);
//--- Release the handles
   ReleaseHandles(req);
//--- Delete the request: this is what tells Python the job is done
   FileDelete(req_path, FILE_COMMON);
   if(ok)
      PrintFormat("OnTimer: request [%s] completed", req.request_id);
   else
      PrintFormat("OnTimer: request [%s] failed", req.request_id);
  }
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Read a text file into a string                                   |
//+------------------------------------------------------------------+
bool ReadFile(const string filepath, string &out_text)
  {
   int fh = FileOpen(filepath, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON, '\n', CP_ACP);
   if(fh == INVALID_HANDLE)
     {
      Print("ReadFile: cannot open ", filepath);
      return false;
     }
   out_text = "";
   while(!FileIsEnding(fh))
      out_text += FileReadString(fh) + "\n";
   FileClose(fh);
   return true;
  }

//+------------------------------------------------------------------+
//| Load the indicator reference table                               |
//+------------------------------------------------------------------+
bool LoadEtalon(const string filepath,
                SEtalonIndicator &etalon[],
                string &etalon_names[])
  {
   string json_str;
   if(!ReadFile(filepath, json_str))
      return false;
   CJAVal js;
   if(!js.Deserialize(json_str, CP_ACP))
     {
      Print("LoadEtalon: JSON parse error");
      return false;
     }
   int count = js["indicators"].Size();
   ArrayResize(etalon, count);
   ArrayResize(etalon_names, count);
   for(int i = 0; i < count; i++)
     {
      etalon_names[i]     = js["indicators"].children[i].key;
      etalon[i].mql5_call = js["indicators"].children[i]["mql5_call"].ToStr();
      //--- params
      int param_count = js["indicators"].children[i]["params"].Size();
      ArrayResize(etalon[i].params, param_count);
      for(int p = 0; p < param_count; p++)
        {
         etalon[i].params[p].name = js["indicators"].children[i]["params"][p]["name"].ToStr();
         etalon[i].params[p].type = js["indicators"].children[i]["params"][p]["type"].ToStr();
        }
      //--- buffers
      int buf_count = js["indicators"].children[i]["buffers"].Size();
      ArrayResize(etalon[i].buffers, buf_count);
      for(int b = 0; b < buf_count; b++)
        {
         etalon[i].buffers[b].name  = js["indicators"].children[i]["buffers"].children[b].key;
         etalon[i].buffers[b].index = (int)js["indicators"].children[i]["buffers"].children[b].ToInt();
        }
     }
   PrintFormat("LoadEtalon: %d indicators loaded", count);
   return true;
  }

//+------------------------------------------------------------------+
//| Find an indicator in the reference table                         |
//+------------------------------------------------------------------+
int FindEtalon(const string name,
               const SEtalonIndicator &etalon[],
               const string &etalon_names[])
  {
   for(int i = 0; i < ArraySize(etalon_names); i++)
      if(etalon_names[i] == name)
         return i;
   return -1;
  }

//+------------------------------------------------------------------+
//| Validate the request against the reference table                 |
//+------------------------------------------------------------------+
bool ValidateRequest(SRequest &req,
                     const SEtalonIndicator &etalon[],
                     const string &etalon_names[])
  {
   bool ok = true;
   for(int i = 0; i < ArraySize(req.indicators); i++)
     {
      string name = req.indicators[i].name;
      int ei = FindEtalon(name, etalon, etalon_names);
      if(ei < 0)
        {
         PrintFormat("VALIDATE ERROR [%s]: not found in the reference table", name);
         ok = false;
         continue;
        }
      int req_pc    = ArraySize(req.indicators[i].param_keys);
      int etalon_pc = ArraySize(etalon[ei].params);
      if(req_pc != etalon_pc)
        {
         PrintFormat("VALIDATE ERROR [%s]: params count %d != etalon %d",
                     name, req_pc, etalon_pc);
         ok = false;
        }
      int check = MathMin(req_pc, etalon_pc);
      for(int p = 0; p < check; p++)
         if(req.indicators[i].param_keys[p] != etalon[ei].params[p].name)
           {
            PrintFormat("VALIDATE ERROR [%s]: param[%d] '%s' != etalon '%s'",
                        name, p,
                        req.indicators[i].param_keys[p],
                        etalon[ei].params[p].name);
            ok = false;
           }
      for(int b = 0; b < ArraySize(req.indicators[i].buffers); b++)
        {
         int req_idx = req.indicators[i].buffers[b].index;
         bool found  = false;
         for(int eb = 0; eb < ArraySize(etalon[ei].buffers); eb++)
            if(etalon[ei].buffers[eb].index == req_idx)
              { found = true; break; }
         if(!found)
           {
            PrintFormat("VALIDATE ERROR [%s]: buffer '%s' index %d is not in the reference table",
                        name, req.indicators[i].buffers[b].col_name, req_idx);
            ok = false;
           }
        }
     }
   if(ok)
      Print("VALIDATE OK: request matches the reference table");
   return ok;
  }

//+------------------------------------------------------------------+
//| Parse the request                                                |
//+------------------------------------------------------------------+
bool ParseRequest(const string json_str, SRequest &req)
  {
   CJAVal js;
   if(!js.Deserialize(json_str, CP_ACP))
     {
      Print("ParseRequest: JSON parse error");
      return false;
     }
   req.request_id = js["request_id"].ToStr();
   req.symbol     = js["symbol"].ToStr();
   req.timeframe  = js["timeframe"].ToStr();
   req.start_date = js["start_date"].ToStr();
   req.end_date   = js["end_date"].ToStr();
   int ind_count = js["indicators"].Size();
   ArrayResize(req.indicators, ind_count);
   for(int i = 0; i < ind_count; i++)
     {
      CJAVal *ind = js["indicators"][i];
      req.indicators[i].name   = ind["name"].ToStr();
      req.indicators[i].handle = INVALID_HANDLE;
      CJAVal *params  = ind["params"];
      int param_count = params.Size();
      ArrayResize(req.indicators[i].param_keys, param_count);
      ArrayResize(req.indicators[i].param_vals, param_count);
      for(int p = 0; p < param_count; p++)
        {
         req.indicators[i].param_keys[p] = params.children[p].key;
         req.indicators[i].param_vals[p] = params.children[p].ToStr();
        }
      CJAVal *buffers = ind["buffers"];
      int buf_count   = buffers.Size();
      ArrayResize(req.indicators[i].buffers, buf_count);
      for(int b = 0; b < buf_count; b++)
        {
         req.indicators[i].buffers[b].col_name = buffers.children[b].key;
         req.indicators[i].buffers[b].index    = (int)buffers.children[b].ToInt();
        }
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Helper: look up a parameter value by its name                    |
//+------------------------------------------------------------------+
string GetParam(const SIndicator &ind, const string key)
  {
   for(int i = 0; i < ArraySize(ind.param_keys); i++)
      if(ind.param_keys[i] == key)
         return ind.param_vals[i];
   return "";
  }

//+------------------------------------------------------------------+
//| String to ENUM conversion                                        |
//+------------------------------------------------------------------+
ENUM_APPLIED_PRICE StrToAppliedPrice(const string s)
  {
   if(s == "PRICE_CLOSE")
      return PRICE_CLOSE;
   if(s == "PRICE_OPEN")
      return PRICE_OPEN;
   if(s == "PRICE_HIGH")
      return PRICE_HIGH;
   if(s == "PRICE_LOW")
      return PRICE_LOW;
   if(s == "PRICE_MEDIAN")
      return PRICE_MEDIAN;
   if(s == "PRICE_TYPICAL")
      return PRICE_TYPICAL;
   if(s == "PRICE_WEIGHTED")
      return PRICE_WEIGHTED;
   return PRICE_CLOSE;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
ENUM_MA_METHOD StrToMaMethod(const string s)
  {
   if(s == "MODE_SMA")
      return MODE_SMA;
   if(s == "MODE_EMA")
      return MODE_EMA;
   if(s == "MODE_SMMA")
      return MODE_SMMA;
   if(s == "MODE_LWMA")
      return MODE_LWMA;
   return MODE_SMA;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
ENUM_STO_PRICE StrToStoPrice(const string s)
  {
   if(s == "STO_LOWHIGH")
      return STO_LOWHIGH;
   if(s == "STO_CLOSECLOSE")
      return STO_CLOSECLOSE;
   return STO_LOWHIGH;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
ENUM_APPLIED_VOLUME StrToAppliedVolume(const string s)
  {
   if(s == "VOLUME_TICK")
      return VOLUME_TICK;
   if(s == "VOLUME_REAL")
      return VOLUME_REAL;
   return VOLUME_TICK;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES StrToTimeframe(const string s)
  {
//--- all 21 MQL5 timeframes
   if(s == "PERIOD_M1")
      return PERIOD_M1;
   if(s == "PERIOD_M2")
      return PERIOD_M2;
   if(s == "PERIOD_M3")
      return PERIOD_M3;
   if(s == "PERIOD_M4")
      return PERIOD_M4;
   if(s == "PERIOD_M5")
      return PERIOD_M5;
   if(s == "PERIOD_M6")
      return PERIOD_M6;
   if(s == "PERIOD_M10")
      return PERIOD_M10;
   if(s == "PERIOD_M12")
      return PERIOD_M12;
   if(s == "PERIOD_M15")
      return PERIOD_M15;
   if(s == "PERIOD_M20")
      return PERIOD_M20;
   if(s == "PERIOD_M30")
      return PERIOD_M30;
   if(s == "PERIOD_H1")
      return PERIOD_H1;
   if(s == "PERIOD_H2")
      return PERIOD_H2;
   if(s == "PERIOD_H3")
      return PERIOD_H3;
   if(s == "PERIOD_H4")
      return PERIOD_H4;
   if(s == "PERIOD_H6")
      return PERIOD_H6;
   if(s == "PERIOD_H8")
      return PERIOD_H8;
   if(s == "PERIOD_H12")
      return PERIOD_H12;
   if(s == "PERIOD_D1")
      return PERIOD_D1;
   if(s == "PERIOD_W1")
      return PERIOD_W1;
   if(s == "PERIOD_MN1")
      return PERIOD_MN1;
   PrintFormat("StrToTimeframe: unknown timeframe '%s' - falling back to PERIOD_H1", s);
   return PERIOD_H1;
  }

//+------------------------------------------------------------------+
//| Build the call signature for the log                             |
//| Example: iRSI("EURUSD", PERIOD_H1, 14, PRICE_CLOSE)              |
//+------------------------------------------------------------------+
string BuildCallString(const SIndicator &ind,
                       const string mql5_call,
                       const string symbol,
                       const string timeframe)
  {
   string s = mql5_call + "(\"" + symbol + "\", " + timeframe;
   for(int p = 0; p < ArraySize(ind.param_keys); p++)
      s += ", " + ind.param_vals[p];
   s += ")";
   return s;
  }

//+------------------------------------------------------------------+
//| Create an indicator handle from mql5_call (all 39 indicators)    |
//+------------------------------------------------------------------+
int CreateHandle(const SIndicator &ind,
                 const string mql5_call,
                 const string symbol,
                 const ENUM_TIMEFRAMES tf)
  {
//--- No parameters besides symbol and period
   if(mql5_call == "iAC")
      return iAC(symbol, tf);
   if(mql5_call == "iAO")
      return iAO(symbol, tf);
   if(mql5_call == "iFractals")
      return iFractals(symbol, tf);
//--- A single int parameter
   if(mql5_call == "iATR")
      return iATR(symbol, tf,
                  (int)StringToInteger(GetParam(ind, "ma_period")));
   if(mql5_call == "iADX")
      return iADX(symbol, tf,
                  (int)StringToInteger(GetParam(ind, "adx_period")));
   if(mql5_call == "iADXWilder")
      return iADXWilder(symbol, tf,
                        (int)StringToInteger(GetParam(ind, "adx_period")));
   if(mql5_call == "iDeMarker")
      return iDeMarker(symbol, tf,
                       (int)StringToInteger(GetParam(ind, "ma_period")));
   if(mql5_call == "iRVI")
      return iRVI(symbol, tf,
                  (int)StringToInteger(GetParam(ind, "ma_period")));
   if(mql5_call == "iWPR")
      return iWPR(symbol, tf,
                  (int)StringToInteger(GetParam(ind, "calc_period")));
   if(mql5_call == "iBearsPower")
      return iBearsPower(symbol, tf,
                         (int)StringToInteger(GetParam(ind, "ma_period")));
   if(mql5_call == "iBullsPower")
      return iBullsPower(symbol, tf,
                         (int)StringToInteger(GetParam(ind, "ma_period")));
//--- ENUM_APPLIED_VOLUME
   if(mql5_call == "iAD")
      return iAD(symbol, tf,
                 StrToAppliedVolume(GetParam(ind, "applied_volume")));
   if(mql5_call == "iBWMFI")
      return iBWMFI(symbol, tf,
                    StrToAppliedVolume(GetParam(ind, "applied_volume")));
   if(mql5_call == "iOBV")
      return iOBV(symbol, tf,
                  StrToAppliedVolume(GetParam(ind, "applied_volume")));
   if(mql5_call == "iVolumes")
      return iVolumes(symbol, tf,
                      StrToAppliedVolume(GetParam(ind, "applied_volume")));
//--- int + ENUM_APPLIED_PRICE
   if(mql5_call == "iRSI")
      return iRSI(symbol, tf,
                  (int)StringToInteger(GetParam(ind, "ma_period")),
                  StrToAppliedPrice(GetParam(ind, "applied_price")));
   if(mql5_call == "iMomentum")
      return iMomentum(symbol, tf,
                       (int)StringToInteger(GetParam(ind, "mom_period")),
                       StrToAppliedPrice(GetParam(ind, "applied_price")));
   if(mql5_call == "iTriX")
      return iTriX(symbol, tf,
                   (int)StringToInteger(GetParam(ind, "ma_period")),
                   StrToAppliedPrice(GetParam(ind, "applied_price")));
   if(mql5_call == "iCCI")
      return iCCI(symbol, tf,
                  (int)StringToInteger(GetParam(ind, "ma_period")),
                  StrToAppliedPrice(GetParam(ind, "applied_price")));
//--- double parameters
   if(mql5_call == "iSAR")
      return iSAR(symbol, tf,
                  StringToDouble(GetParam(ind, "step")),
                  StringToDouble(GetParam(ind, "maximum")));
//--- int + int + ENUM_APPLIED_PRICE
   if(mql5_call == "iDEMA")
      return iDEMA(symbol, tf,
                   (int)StringToInteger(GetParam(ind, "ma_period")),
                   (int)StringToInteger(GetParam(ind, "ma_shift")),
                   StrToAppliedPrice(GetParam(ind, "applied_price")));
   if(mql5_call == "iTEMA")
      return iTEMA(symbol, tf,
                   (int)StringToInteger(GetParam(ind, "ma_period")),
                   (int)StringToInteger(GetParam(ind, "ma_shift")),
                   StrToAppliedPrice(GetParam(ind, "applied_price")));
   if(mql5_call == "iFrAMA")
      return iFrAMA(symbol, tf,
                    (int)StringToInteger(GetParam(ind, "ma_period")),
                    (int)StringToInteger(GetParam(ind, "ma_shift")),
                    StrToAppliedPrice(GetParam(ind, "applied_price")));
//--- int + int + ENUM_MA_METHOD + ENUM_APPLIED_PRICE
   if(mql5_call == "iMA")
      return iMA(symbol, tf,
                 (int)StringToInteger(GetParam(ind, "ma_period")),
                 (int)StringToInteger(GetParam(ind, "ma_shift")),
                 StrToMaMethod(GetParam(ind, "ma_method")),
                 StrToAppliedPrice(GetParam(ind, "applied_price")));
   if(mql5_call == "iStdDev")
      return iStdDev(symbol, tf,
                     (int)StringToInteger(GetParam(ind, "ma_period")),
                     (int)StringToInteger(GetParam(ind, "ma_shift")),
                     StrToMaMethod(GetParam(ind, "ma_method")),
                     StrToAppliedPrice(GetParam(ind, "applied_price")));
//--- int + int + double + ENUM_APPLIED_PRICE
   if(mql5_call == "iBands")
      return iBands(symbol, tf,
                    (int)StringToInteger(GetParam(ind, "bands_period")),
                    (int)StringToInteger(GetParam(ind, "bands_shift")),
                    StringToDouble(GetParam(ind, "deviation")),
                    StrToAppliedPrice(GetParam(ind, "applied_price")));
//--- int + int + ENUM_MA_METHOD + ENUM_APPLIED_VOLUME
   if(mql5_call == "iChaikin")
      return iChaikin(symbol, tf,
                      (int)StringToInteger(GetParam(ind, "fast_ma_period")),
                      (int)StringToInteger(GetParam(ind, "slow_ma_period")),
                      StrToMaMethod(GetParam(ind, "ma_method")),
                      StrToAppliedVolume(GetParam(ind, "applied_volume")));
   if(mql5_call == "iForce")
      return iForce(symbol, tf,
                    (int)StringToInteger(GetParam(ind, "ma_period")),
                    StrToMaMethod(GetParam(ind, "ma_method")),
                    StrToAppliedVolume(GetParam(ind, "applied_volume")));
   if(mql5_call == "iMFI")
      return iMFI(symbol, tf,
                  (int)StringToInteger(GetParam(ind, "ma_period")),
                  StrToAppliedVolume(GetParam(ind, "applied_volume")));
//--- int + int + int + ENUM_APPLIED_PRICE
   if(mql5_call == "iIchimoku")
      return iIchimoku(symbol, tf,
                       (int)StringToInteger(GetParam(ind, "tenkan_sen")),
                       (int)StringToInteger(GetParam(ind, "kijun_sen")),
                       (int)StringToInteger(GetParam(ind, "senkou_span_b")));
//--- Long parameter lists
   if(mql5_call == "iAMA")
      return iAMA(symbol, tf,
                  (int)StringToInteger(GetParam(ind, "ama_period")),
                  (int)StringToInteger(GetParam(ind, "fast_ma_period")),
                  (int)StringToInteger(GetParam(ind, "slow_ma_period")),
                  (int)StringToInteger(GetParam(ind, "ama_shift")),
                  StrToAppliedPrice(GetParam(ind, "applied_price")));
   if(mql5_call == "iMACD")
      return iMACD(symbol, tf,
                   (int)StringToInteger(GetParam(ind, "fast_ema_period")),
                   (int)StringToInteger(GetParam(ind, "slow_ema_period")),
                   (int)StringToInteger(GetParam(ind, "signal_period")),
                   StrToAppliedPrice(GetParam(ind, "applied_price")));
   if(mql5_call == "iOsMA")
      return iOsMA(symbol, tf,
                   (int)StringToInteger(GetParam(ind, "fast_ema_period")),
                   (int)StringToInteger(GetParam(ind, "slow_ema_period")),
                   (int)StringToInteger(GetParam(ind, "signal_period")),
                   StrToAppliedPrice(GetParam(ind, "applied_price")));
   if(mql5_call == "iEnvelopes")
      return iEnvelopes(symbol, tf,
                        (int)StringToInteger(GetParam(ind, "ma_period")),
                        (int)StringToInteger(GetParam(ind, "ma_shift")),
                        StrToMaMethod(GetParam(ind, "ma_method")),
                        StrToAppliedPrice(GetParam(ind, "applied_price")),
                        StringToDouble(GetParam(ind, "deviation")));
   if(mql5_call == "iStochastic")
      return iStochastic(symbol, tf,
                         (int)StringToInteger(GetParam(ind, "Kperiod")),
                         (int)StringToInteger(GetParam(ind, "Dperiod")),
                         (int)StringToInteger(GetParam(ind, "slowing")),
                         StrToMaMethod(GetParam(ind, "ma_method")),
                         StrToStoPrice(GetParam(ind, "price_field")));
   if(mql5_call == "iVIDyA")
      return iVIDyA(symbol, tf,
                    (int)StringToInteger(GetParam(ind, "cmo_period")),
                    (int)StringToInteger(GetParam(ind, "ema_period")),
                    (int)StringToInteger(GetParam(ind, "ma_shift")),
                    StrToAppliedPrice(GetParam(ind, "applied_price")));
   if(mql5_call == "iAlligator")
      return iAlligator(symbol, tf,
                        (int)StringToInteger(GetParam(ind, "jaw_period")),
                        (int)StringToInteger(GetParam(ind, "jaw_shift")),
                        (int)StringToInteger(GetParam(ind, "teeth_period")),
                        (int)StringToInteger(GetParam(ind, "teeth_shift")),
                        (int)StringToInteger(GetParam(ind, "lips_period")),
                        (int)StringToInteger(GetParam(ind, "lips_shift")),
                        StrToMaMethod(GetParam(ind, "ma_method")),
                        StrToAppliedPrice(GetParam(ind, "applied_price")));
   if(mql5_call == "iGator")
      return iGator(symbol, tf,
                    (int)StringToInteger(GetParam(ind, "jaw_period")),
                    (int)StringToInteger(GetParam(ind, "jaw_shift")),
                    (int)StringToInteger(GetParam(ind, "teeth_period")),
                    (int)StringToInteger(GetParam(ind, "teeth_shift")),
                    (int)StringToInteger(GetParam(ind, "lips_period")),
                    (int)StringToInteger(GetParam(ind, "lips_shift")),
                    StrToMaMethod(GetParam(ind, "ma_method")),
                    StrToAppliedPrice(GetParam(ind, "applied_price")));
   PrintFormat("CreateHandle: unknown mql5_call '%s'", mql5_call);
   return INVALID_HANDLE;
  }

//+------------------------------------------------------------------+
//| Create every handle listed in the request                        |
//+------------------------------------------------------------------+
bool CreateAllHandles(SRequest &req,
                      const SEtalonIndicator &etalon[],
                      const string &etalon_names[])
  {
   ENUM_TIMEFRAMES tf = StrToTimeframe(req.timeframe);
   bool ok = true;
   for(int i = 0; i < ArraySize(req.indicators); i++)
     {
      int ei = FindEtalon(req.indicators[i].name, etalon, etalon_names);
      if(ei < 0)
        {
         ok = false;
         continue;
        }
      int handle = CreateHandle(req.indicators[i], etalon[ei].mql5_call, req.symbol, tf);
      if(handle == INVALID_HANDLE)
        {
         PrintFormat("CreateAllHandles: INVALID_HANDLE for %s",
                     BuildCallString(req.indicators[i], etalon[ei].mql5_call,
                                     req.symbol, req.timeframe));
         ok = false;
        }
      else
        {
         req.indicators[i].handle = handle;
         PrintFormat("CreateAllHandles: %s handle=%d",
                     BuildCallString(req.indicators[i], etalon[ei].mql5_call,
                                     req.symbol, req.timeframe),
                     handle);
        }
     }
   return ok;
  }

//+------------------------------------------------------------------+
//| Print the parsed request                                         |
//+------------------------------------------------------------------+
void PrintRequest(const SRequest &req)
  {
   PrintFormat("=== REQUEST [%s] ===", req.request_id);
   PrintFormat("Symbol:    %s", req.symbol);
   PrintFormat("Timeframe: %s", req.timeframe);
   PrintFormat("Period:    %s -> %s", req.start_date, req.end_date);
   PrintFormat("Indicators: %d", ArraySize(req.indicators));
   for(int i = 0; i < ArraySize(req.indicators); i++)
     {
      PrintFormat("  [%d] %s  (handle=%d)",
                  i, req.indicators[i].name, req.indicators[i].handle);
      for(int p = 0; p < ArraySize(req.indicators[i].param_keys); p++)
         PrintFormat("       param: %s = %s",
                     req.indicators[i].param_keys[p],
                     req.indicators[i].param_vals[p]);
      for(int b = 0; b < ArraySize(req.indicators[i].buffers); b++)
         PrintFormat("       buffer[%d] -> csv_col: '%s'",
                     req.indicators[i].buffers[b].index,
                     req.indicators[i].buffers[b].col_name);
     }
  }

//+------------------------------------------------------------------+
//| Find the first request file in the Bridge folder                 |
//| Returns the file name, or "" when there is nothing to do         |
//+------------------------------------------------------------------+
string FindRequestFile()
  {
   string result = "";
   long   search_handle;
   string filename;
   search_handle = FileFindFirst("Bridge\\request_*.json", filename, FILE_COMMON);
   if(search_handle != INVALID_HANDLE)
     {
      result = "Bridge\\" + filename;
      FileFindClose(search_handle);
     }
   return result;
  }

//+------------------------------------------------------------------+
//| Write the CSV response file                                      |
//+------------------------------------------------------------------+
bool WriteCSV(const SRequest &req,
              const string response_file)
  {
   string tmp_file = response_file + ".tmp";
//--- Count the bars inside the requested range
   datetime dt_from = StringToTime(req.start_date);
   datetime dt_to   = StringToTime(req.end_date);
   ENUM_TIMEFRAMES tf = StrToTimeframe(req.timeframe);
//--- Price precision must come from the requested symbol. _Digits is the
//    precision of the CHART the EA sits on, which silently truncated
//    prices whenever the request asked for a different instrument.
   int digits = (int)SymbolInfoInteger(req.symbol, SYMBOL_DIGITS);
   if(digits <= 0)
     {
      //--- The symbol may simply not be in Market Watch yet.
      SymbolSelect(req.symbol, true);
      digits = (int)SymbolInfoInteger(req.symbol, SYMBOL_DIGITS);
     }
   if(digits <= 0)
     {
      PrintFormat("WriteCSV: cannot read SYMBOL_DIGITS of %s", req.symbol);
      return false;
     }
   MqlRates rates[];
   int bars = CopyRates(req.symbol, tf, dt_from, dt_to, rates);
   if(bars <= 0)
     {
      PrintFormat("WriteCSV: CopyRates returned %d", bars);
      return false;
     }
//--- Wait until every indicator buffer is fully calculated.
//    Without this the first hundreds of bars come out as zeros.
   int timeout  = 10;  // seconds
   int elapsed  = 0;
   bool ready   = false;
   while(elapsed < timeout)
     {
      ready = true;
      for(int i = 0; i < ArraySize(req.indicators); i++)
        {
         if(BarsCalculated(req.indicators[i].handle) < bars)
           { ready = false; break; }
        }
      if(ready)
         break;
      Sleep(1000);
      elapsed++;
     }
   if(!ready)
     {
      Print("WriteCSV: timed out waiting for the buffers");
      return false;
     }
//--- Open the temporary file for writing
   int fh = FileOpen(tmp_file, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON, '\n', CP_ACP);
   if(fh == INVALID_HANDLE)
     {
      Print("WriteCSV: cannot open ", tmp_file);
      return false;
     }
//--- Header: datetime,open,high,low,close plus one column per buffer
   string header = "datetime,open,high,low,close";
   for(int i = 0; i < ArraySize(req.indicators); i++)
      for(int b = 0; b < ArraySize(req.indicators[i].buffers); b++)
         header += "," + req.indicators[i].buffers[b].col_name;
   FileWriteString(fh, header + "\n");
//--- Storage for the copied buffers.
//    MQL5 has no double[][][], so struct wrappers are used instead.
   struct SOneBuf     { double data[]; };
   struct SIndBufs    { SOneBuf bufs[]; };
   int ind_count = ArraySize(req.indicators);
   SIndBufs buf_data[];
   ArrayResize(buf_data, ind_count);
//--- Copy each buffer into its own array
   for(int i = 0; i < ind_count; i++)
     {
      int nb = ArraySize(req.indicators[i].buffers);
      ArrayResize(buf_data[i].bufs, nb);
      for(int b = 0; b < nb; b++)
        {
         ArrayResize(buf_data[i].bufs[b].data, bars);
         int copied = CopyBuffer(req.indicators[i].handle,
                                 req.indicators[i].buffers[b].index,
                                 dt_from, dt_to,
                                 buf_data[i].bufs[b].data);
         if(copied != bars)
           {
            PrintFormat("WriteCSV: CopyBuffer [%s buf=%d] returned %d of %d",
                        req.indicators[i].name,
                        req.indicators[i].buffers[b].index,
                        copied, bars);
            FileClose(fh);
            FileDelete(tmp_file, FILE_COMMON);
            return false;
           }
        }
     }
//--- Write the rows oldest first. CopyRates fills index 0 with the
//    oldest bar, so a forward loop already gives chronological order.
   for(int bar = 0; bar < bars; bar++)
     {
      string row = TimeToString(rates[bar].time, TIME_DATE | TIME_MINUTES)
                   + "," + DoubleToString(rates[bar].open,  digits)
                   + "," + DoubleToString(rates[bar].high,  digits)
                   + "," + DoubleToString(rates[bar].low,   digits)
                   + "," + DoubleToString(rates[bar].close, digits);
      for(int i = 0; i < ind_count; i++)
         for(int b = 0; b < ArraySize(req.indicators[i].buffers); b++)
            row += "," + DoubleToString(buf_data[i].bufs[b].data[bar], 8);
      FileWriteString(fh, row + "\n");
     }
   FileClose(fh);
//--- Atomic publish: rename tmp into the final name
   if(FileIsExist(response_file, FILE_COMMON))
      FileDelete(response_file, FILE_COMMON);
   FileMove(tmp_file, FILE_COMMON, response_file, FILE_COMMON);
   PrintFormat("WriteCSV: %d bars written to %s", bars, response_file);
   return true;
  }

//+------------------------------------------------------------------+
//| Release every indicator handle                                   |
//+------------------------------------------------------------------+
void ReleaseHandles(SRequest &req)
  {
   for(int i = 0; i < ArraySize(req.indicators); i++)
      if(req.indicators[i].handle != INVALID_HANDLE)
        {
         IndicatorRelease(req.indicators[i].handle);
         req.indicators[i].handle = INVALID_HANDLE;
        }
  }
//+------------------------------------------------------------------+
