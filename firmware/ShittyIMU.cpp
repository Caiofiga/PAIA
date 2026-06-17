#include "ShittyIMU.h"

ShittyIMU::ShittyIMU(TwoWire &wPort, uint8_t sdaPin, uint8_t sclPin, uint8_t address) {
  _wirePort = &wPort;
  _sda = sdaPin;
  _scl = sclPin;
  _addr = address;
}

bool ShittyIMU::begin() {
  _wirePort->begin(_sda, _scl);
  delay(100);

  // Wake up the clone chip
  _wirePort->beginTransmission(_addr);
  _wirePort->write(0x6B);
  _wirePort->write(0x00);
  if (_wirePort->endTransmission() != 0) return false;

  // ACCEL_CONFIG: AFS_SEL=1 → ±4g (8192 LSB/g)
  _wirePort->beginTransmission(_addr);
  _wirePort->write(0x1C);
  _wirePort->write(0x08);
  if (_wirePort->endTransmission() != 0) return false;

  // GYRO_CONFIG: FS_SEL=1 → ±500°/s (65.5 LSB/°/s)
  _wirePort->beginTransmission(_addr);
  _wirePort->write(0x1B);
  _wirePort->write(0x08);
  return (_wirePort->endTransmission() == 0);
}

bool ShittyIMU::update() {
  _wirePort->beginTransmission(_addr);
  _wirePort->write(0x3B); 
  if (_wirePort->endTransmission(false) != 0) return false;

  _wirePort->requestFrom(_addr, (uint8_t)14);

  if (_wirePort->available() >= 14) {
    data.rawAccelX = (_wirePort->read() << 8) | _wirePort->read();  //bitwise shift to byte, add low byte after
    data.rawAccelY = (_wirePort->read() << 8) | _wirePort->read();
    data.rawAccelZ = (_wirePort->read() << 8) | _wirePort->read();
    
    _wirePort->read(); _wirePort->read();
    
    data.rawGyroX  = (_wirePort->read() << 8) | _wirePort->read();
    data.rawGyroY  = (_wirePort->read() << 8) | _wirePort->read();
    data.rawGyroZ  = (_wirePort->read() << 8) | _wirePort->read();
    return true;
  }
  return false;
}