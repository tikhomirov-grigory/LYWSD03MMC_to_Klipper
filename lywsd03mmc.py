import logging
import threading
import asyncio
import time
from bleak import BleakScanner
from bthome_ble import BTHomeBluetoothDeviceData
from home_assistant_bluetooth import BluetoothServiceInfoBleak

class LYWSD03MMC:
    def __init__(self, config):
        self.printer = config.get_printer()
        self.reactor = self.printer.get_reactor()
        self.name = config.get_name().split()[-1]
        self.min_temp = self.max_temp = 0.
        self.temp_callback = None
        self.address = config.get('address', '').upper()
        self.temp = 0.0
        self.humidity = 0.0
        self.battery = 0.0
        self.parser = BTHomeBluetoothDeviceData()

        if not self.address:
            return

        self.printer.add_object("lywsd03mmc " + self.name, self)
        
        self.thread = threading.Thread(target=self._run_bluetooth_loop, daemon=True)
        self.thread.start()

    def setup_minmax(self, min_temp, max_temp):
        self.min_temp = min_temp
        self.max_temp = max_temp

    def setup_callback(self, cb):
        self.temp_callback = cb

    def _run_bluetooth_loop(self):
        time.sleep(5)
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        try:
            loop.run_until_complete(self._scanner())
        except Exception:
            logging.exception("LYWSD03MMC: Ошибка в потоке Bluetooth")

    async def _scanner(self):
        def detection_callback(device, advertising_data):
            if device.address.upper() == self.address:
                service_info = BluetoothServiceInfoBleak(
                    name=device.name or device.address, address=device.address,
                    rssi=advertising_data.rssi, manufacturer_data=advertising_data.manufacturer_data,
                    service_data=advertising_data.service_data, service_uuids=advertising_data.service_uuids,
                    source="local", device=device, advertisement=advertising_data,
                    connectable=False, time=asyncio.get_event_loop().time(),
                    tx_power=advertising_data.tx_power
                )
                result = self.parser.update(service_info)
                if result:
                    for key, sensor in result.entity_values.items():
                        if key.key == 'temperature':
                            self.temp = sensor.native_value
                            if self.temp_callback:
                                self.reactor.register_callback(
                                    lambda e: self.temp_callback(self.reactor.monotonic(),
                                                              self.temp))
                        elif key.key == 'humidity':
                            self.humidity = sensor.native_value
                        elif key.key == 'battery':
                            self.battery = sensor.native_value

        logging.info("LYWSD03MMC: Сканер запущен для %s", self.address)
        while True:
            try:
                async with BleakScanner(detection_callback):
                    while True:
                        await asyncio.sleep(1)
            except Exception:
                await asyncio.sleep(5)

    def stats(self, eventtime):
        return False, ""

    def get_status(self, eventtime):
        return {
            'temperature': self.temp,
            'humidity': self.humidity,
            'battery': self.battery
        }

    def load_config(config):
        pheaters = config.get_printer().load_object(config, "heaters")
        pheaters.add_sensor_factory("LYWSD03MMC", LYWSD03MMC)
        return LYWSD03MMC(config)
