import vplaned
import zmq
import unittest
from unittest.mock import patch
from unittest.mock import MagicMock


class MockZmqSocket(MagicMock):

    def __init__(self, **kwds):
        super().__init__(**kwds)
        self._connected = False

    def connect(self, endpoint):
        assert not self._connected
        assert endpoint != ""
        self._connected = True

    def close(self):
        assert self._connected
        self._connected = False


class MockZmqContext(MagicMock):

    def __init__(self, **kwds):
        super().__init__(**kwds)
        self._destroyed = False
        self.IPV6 = None
        self.RCVTIMEO = None

    def socket(self, sock_type):
        assert not self._destroyed
        assert self.IPV6 == 1
        assert self.RCVTIMEO is not None
        assert sock_type == zmq.REQ
        return MockZmqSocket()

    def destroy(self, linger):
        assert not self._destroyed
        self._destroyed = True


@patch.object(zmq.Context, "instance", MockZmqContext)
class TestController(unittest.TestCase):

    def test_store_success(self):
        out = {"path": {"to": {"object": {"__SET__": "command 1",
                                          "__INTERFACE__": "ALL"}}}}
        with vplaned.Controller() as ctrl:
            ctrl._store_socket.send_json.side_effect = \
                lambda json: self.assertTrue(json == out)
            ctrl._store_socket.recv_string.return_value = "OK"
            ctrl.store("path to object", "command 1", action="SET")

    def test_store_fail(self):
        out = {"path": {"to": {"object": {"__DELETE__": "command 2",
                                          "__INTERFACE__": "ALL"}}}}
        with vplaned.Controller() as ctrl:
            ctrl._store_socket.send_json.side_effect = \
                lambda json: self.assertTrue(json == out)
            ctrl._store_socket.recv_string.return_value = "FAIL"
            with self.assertRaises(vplaned.ControllerException):
                ctrl.store("path to object", "command 2", action="DELETE")

    def test_store_action_exception(self):
        with self.assertRaises(vplaned.ControllerException):
            with vplaned.Controller() as ctrl:
                ctrl._store_socket.recv_string.return_value = "OK"
                ctrl.store("path to object", "command 2")

    def test_get_dataplanes_success(self):
        data = {"dataplanes": [{"id": 0, "control": "ipc:///dev/null"},
                               {"id": 1, "control": "ipc:///dev/nuller"}]}
        with vplaned.Controller() as ctrl:
            ctrl._cfg_socket.send_string.side_effect = \
                lambda string: self.assertTrue(string == "GETVPCONFIG")
            ctrl._cfg_socket.recv_string.return_value = "OK"
            ctrl._cfg_socket.recv_json.return_value = data
            dps = list(ctrl.get_dataplanes())
            self.assertEqual(dps[0].id, 0)
            self.assertEqual(dps[1].id, 1)
            self.assertEqual(dps[0].control, "ipc:///dev/null")
            self.assertEqual(dps[1].control, "ipc:///dev/nuller")

    def test_get_dataplanes_empty_list(self):
        data = {"dataplanes": []}
        with vplaned.Controller() as ctrl:
            ctrl._cfg_socket.send_string.side_effect = \
                lambda string: self.assertTrue(string == "GETVPCONFIG")
            ctrl._cfg_socket.recv_string.return_value = "OK"
            ctrl._cfg_socket.recv_json.return_value = data
            dps = list(ctrl.get_dataplanes())
            self.assertFalse(dps)

    def test_get_dataplanes_fail(self):
        with vplaned.Controller() as ctrl:
            ctrl._cfg_socket.send_string.side_effect = \
                lambda string: self.assertTrue(string == "GETVPCONFIG")
            ctrl._cfg_socket.recv_string.return_value = "FAILURE"
            with self.assertRaises(vplaned.ControllerException):
                dps = list(ctrl.get_dataplanes())


@patch.object(zmq.Context, "instance", MockZmqContext)
class TestDataplane(unittest.TestCase):

    def test_string_command_success(self):
        data = {"dataplanes": [{"id": 0, "control": "ipc:///dev/null",
                                "local": True}]}
        with vplaned.Controller() as ctrl:
            ctrl._cfg_socket.recv_string.return_value = "OK"
            ctrl._cfg_socket.recv_json.return_value = data
            dps = list(ctrl.get_dataplanes())
            self.assertEqual(dps[0].id, 0)
            self.assertTrue(dps[0].local)
            self.assertEqual(dps[0].control, "ipc:///dev/null")
            with dps[0]:
                dps[0]._socket.send_string.side_effect = \
                    lambda string: self.assertTrue(string == "command")
                dps[0]._socket.recv_string.side_effect = ["OK", "some result"]
                self.assertEqual(dps[0].string_command("command"),
                                 "some result")

    def test_json_command_success(self):
        data = {"dataplanes": [{"id": 0, "control": "ipc:///dev/null",
                                "local": False, "stuff": "good stuff"}]}
        with vplaned.Controller() as ctrl:
            ctrl._cfg_socket.recv_string.return_value = "OK"
            ctrl._cfg_socket.recv_json.return_value = data
            dps = list(ctrl.get_dataplanes())
            self.assertEqual(dps[0].id, 0)
            self.assertFalse(dps[0].local)
            self.assertEqual(dps[0].stuff, "good stuff")
            self.assertEqual(dps[0].control, "ipc:///dev/null")
            with dps[0]:
                dps[0]._socket.send_string.side_effect = \
                    lambda string: self.assertEqual(string, "command")
                dps[0]._socket.recv_string.return_value = "OK"
                dps[0]._socket.recv_json.return_value = {"best":
                                                         {"json": "ever"}}
                self.assertEqual(dps[0].json_command("command"),
                                 {"best": {"json": "ever"}})

    def test_string_command_fail(self):
        data = {"dataplanes": [{"id": 0, "control": "ipc:///dev/null",
                                "local": True}]}
        with vplaned.Controller() as ctrl:
            ctrl._cfg_socket.recv_string.return_value = "OK"
            ctrl._cfg_socket.recv_json.return_value = data
            dps = list(ctrl.get_dataplanes())
            self.assertEqual(dps[0].id, 0)
            self.assertTrue(dps[0].local)
            self.assertEqual(dps[0].control, "ipc:///dev/null")
            with dps[0]:
                dps[0]._socket.send_string.side_effect = \
                    lambda string: self.assertEqual(string, "command")
                dps[0]._socket.recv_string.return_value = "FAIL"
                with self.assertRaises(vplaned.DataplaneException):
                    dps[0].string_command("command")

    def test_json_command_fail(self):
        data = {"dataplanes": [{"id": 0, "control": "ipc:///dev/null",
                                "local": False, "stuff": "good stuff"}]}
        with vplaned.Controller() as ctrl:
            ctrl._cfg_socket.recv_string.return_value = "OK"
            ctrl._cfg_socket.recv_json.return_value = data
            dps = list(ctrl.get_dataplanes())
            self.assertEqual(dps[0].id, 0)
            self.assertFalse(dps[0].local)
            self.assertEqual(dps[0].stuff, "good stuff")
            self.assertEqual(dps[0].control, "ipc:///dev/null")
            with dps[0]:
                dps[0]._socket.send_string.side_effect = \
                    lambda string: self.assertEqual(string, "command")
                dps[0]._socket.recv_string.return_value = "FAIL"
                with self.assertRaises(vplaned.DataplaneException):
                    dps[0].json_command("command")


@patch.object(zmq.Context, "instance", MockZmqContext)
class TestInterface(unittest.TestCase):

    def test_multiple_interfaces(self):
        data = {"dataplanes": [{"interfaces": [{"index": 6, "name": "dp0s3",
                                                "state": "up"},
                                               {"index": 7, "name": "dp0s7",
                                                "state": "up"},
                                               {"index": 8, "name": "dp0s9",
                                                "state": "down"}]}]}
        with vplaned.Controller() as ctrl:
            ctrl._cfg_socket.recv_string.return_value = "OK"
            ctrl._cfg_socket.recv_json.return_value = data
            dps = list(ctrl.get_dataplanes())

            self.assertEqual(len(dps[0].interfaces.keys()), 3)
            self.assertEqual(dps[0].interfaces["dp0s3"].state, "up")
            self.assertEqual(dps[0].interfaces["dp0s7"].state, "up")
            self.assertEqual(dps[0].interfaces["dp0s9"].state, "down")
            self.assertEqual(dps[0].interfaces["dp0s3"].index, 6)
            self.assertEqual(dps[0].interfaces["dp0s7"].index, 7)
            self.assertEqual(dps[0].interfaces["dp0s9"].index, 8)
            self.assertEqual(dps[0].interfaces["dp0s3"].dp_id, 0)
            self.assertEqual(dps[0].interfaces["dp0s7"].dp_id, 0)
            self.assertEqual(dps[0].interfaces["dp0s9"].dp_id, 0)
            with self.assertRaises(KeyError):
                dps[0].interfaces["dp0s1"]

    def test_no_interfaces(self):
        data = {"dataplanes": [{"interfaces": []}]}
        with vplaned.Controller() as ctrl:
            ctrl._cfg_socket.recv_string.return_value = "OK"
            ctrl._cfg_socket.recv_json.return_value = data
            dps = list(ctrl.get_dataplanes())

            self.assertEqual(len(dps[0].interfaces.keys()), 0)
            with self.assertRaises(KeyError):
                dps[0].interfaces["dp0s1"]

    def test_invalid_name_fail(self):
        with self.assertRaises(vplaned.InterfaceException):
            vplaned.Interface({"index": 6, "name": "not_a_real_name"})
        self.assertEqual(vplaned.Interface.get_dp_id("not_a_real_name"), None)


if __name__ == '__main__':
    unittest.main()
