#ifndef SHITTY_IMU_H
#define SHITTY_IMU_H

#include <Arduino.h>
#include <Wire.h>

struct ShittyData {
  int16_t rawAccelX, rawAccelY, rawAccelZ;
  int16_t rawGyroX, rawGyroY, rawGyroZ;
};

class ShittyIMU {
  public:
    ShittyIMU(TwoWire &wPort, uint8_t sdaPin, uint8_t sclPin, uint8_t address = 0x68);
    bool begin();
    bool update();
    ShittyData data;

  private:
    TwoWire *_wirePort;
    uint8_t _sda;
    uint8_t _scl;
    uint8_t _addr;
};

#endif