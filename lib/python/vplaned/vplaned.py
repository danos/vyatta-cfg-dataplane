# Copyright (c) 2017-2018, AT&T Intellectual Property. All rights reserved.
# Copyright (c) 2015 Brocade Communications Systems, Inc.
# All Rights Reserved.
#
# SPDX-License-Identifier: LGPL-2.1-only
"""Python3 vplane-controller API.

This module exports 2 classes, Controller and Dataplane.
The Controller can be used to store config command to the dataplane(s), or to
generate a Dataplane object for each connected dataplane(s) (local/remote).
The Dataplane object will have all the information returned by the Controller
as attributes. EG: dataplane.local, dataplane.control, etc.
The "interfaces" attribute is a dictionary keyed on interface name associated
with a corresponding Interface object, which similarly holds state in
attributes like index, state, name, etc.
Generate is intended in the Python sense, so the Dataplane class should not be
instantiated manually. Instead the Controller.get_dataplanes() generator should
be used. Examples:

from vplaned import Controller

with Controller() as controller:
    for dp in controller.get_dataplanes():
        for name, intf in dp.interfaces.items():
            intf.state
        with dp:
            dp.json_command("netflow show")

with Controller(store_endpoint="tcp://1.2.3.4:5678") as controller:
    controller.store("interface dataplane netflow dp1s12",
                     "netflow disable dp1s12")

Note that the store function now supports two messaging modes: the old space
delimited text command (as shown above). And the 'new' messaging mode using
protocol buffers. The protocol buffers use of the store() function requires an
additional argument: cmd_name.

In case of errors with the controller or dataplane runtime commands,
ControllerException or DataplaneException will be raised respectively.
In case of connectivity errors, ZMQError will be raised.

Note that thanks to Python's ContextManager pattern, no cleanup/disconnect is
required. The "with" statement will take care of everything automagically.
"""
import sys
import os
import re
import zmq

class InterfaceException(Exception):
    pass


class DataplaneException(Exception):
    pass


class ControllerException(Exception):
    pass


class Interface:

    """Interface object. This will be automatically generated and added to a
    Dataplane object's "interfaces" attribute dictionary, keyed by the name."""

    def __init__(self, json):
        for key, value in json.items():
            setattr(self, key, value)

        self.dp_id = Interface.get_dp_id(self.name)
        if self.dp_id is None:
            raise InterfaceException("Invalid name: {}".format(self.name))

    @classmethod
    def get_dp_id(cls, interface_name):
        """Parse an interface name and return the dataplane ID as an integer"""
        m = re.match("^[a-z]+(\d+)", interface_name)
        if m is None:
            return None

        return int(m.group(1))


class Dataplane:

    """Dataplane object. It is strongly recommended to avoid creating this
    object manually. Instead, use the Controller.get_dataplanes() generator.
    All the information that vplane-controller has about a dataplane will be
    stored in this object as attributes. EG: dp.local, dp.control, etc.
    The "interfaces" attribute will be a dictionary with interface names as key
    and Interface objects as values.

    Implements ContextManager pattern, so use through "with" statement."""

    def __init__(self, ctx, json):
        self._ctx = ctx
        self._socket = None
        self.interfaces = {}
        for key, value in json.items():
            # The interfaces json object is treated differently by the
            # controller, it returns as an array of flat json objects so we
            # need this bit of magic string matching to make it work
            if key == "interfaces":
                for intf in value:
                    self.interfaces[intf["name"]] = Interface(intf)
            else:
                setattr(self, key, value)

    def __enter__(self):
        self._socket = self._ctx.socket(zmq.REQ)
        # Dataplane/Controller in 2.0.0 do not return "control"
        if hasattr(self, "control"):
            self._socket.connect(self.control)
        else:
            self._socket.connect("ipc:///var/run/vplane.socket")
        return self

    def __exit__(self, *exc):
        self._socket.close()

    def string_command(self, string):
        """send a command and return the dataplane response as a string"""
        self._socket.send_string(string)
        rc = self._socket.recv_string()
        if rc != "OK":
            raise DataplaneException("Command {} returned {}".format(string,
                                                                     rc))

        return self._socket.recv_string()

    def json_command(self, string):
        """send a command and return the dataplane response as a json object"""
        self._socket.send_string(string)
        rc = self._socket.recv_string()
        if rc != "OK":
            raise DataplaneException("Command {} returned {}".format(string,
                                                                     rc))

        return self._socket.recv_json()


class Controller:

    """Controller object. Can be used to generate Dataplane objects or to store
    config.
    Implements ContextManager pattern, so use through "with" statement.
    """

    def __init__(self, store_endpoint="ipc:///var/run/vyatta/vplaned.socket",
                 cfg_endpoint="ipc:///var/run/vyatta/vplaned-config.socket"):
        self._ctx = None
        self._store_socket = None
        self._cfg_socket = None
        self._store_endpoint = store_endpoint
        self._cfg_endpoint = cfg_endpoint

    def __enter__(self):
        self._ctx = zmq.Context.instance()
        # ZMQ sockopts set in the context will be used by all sockets
        self._ctx.IPV6 = 1
        self._ctx.RCVTIMEO = 10000
        # All messages are ACK'ed so no need to wait when the socket is closed
        self._ctx.LINGER = 0
        self._store_socket = self._ctx.socket(zmq.REQ)
        self._store_socket.connect(self._store_endpoint)
        self._cfg_socket = self._ctx.socket(zmq.REQ)
        self._cfg_socket.connect(self._cfg_endpoint)
        return self

    def __exit__(self, *exc):
        self._store_socket.close()
        self._cfg_socket.close()

    def get_dataplanes(self):
        """Generator for dataplanes. Will fetch info from the controller about
        all dataplanes, and create an object each and yield it.
        """
        self._cfg_socket.send_string("GETVPCONFIG")
        rc = self._cfg_socket.recv_string()
        if rc != "OK":
            raise ControllerException("GETVPCONFIG returned {}".format(rc))

        json = self._cfg_socket.recv_json()
        if json is None:
            raise ControllerException("GETVPCONFIG returned empty response")

        for dp in json["dataplanes"]:
            yield Dataplane(self._ctx, dp)

    def store(self, path, cmd, interface="ALL",
              action=os.getenv("COMMIT_ACTION"),
              cmd_name=None):
        """Send command to dataplane(s) and store it, associated with the path.
        By default it will apply to all interfaces, "interface" parameter to
        override.
        By default it will use the action defined by the COMMIT_ACTION env
        variable, which is set when in commit mode, "action" parameter to
        override.
        """
        if action is None:
            raise ControllerException(
                "COMMIT_ACTION not found. Not in commit mode?")

        # Create a dictionary, and use a reference to work on it recursively.
        # The dataplane expect the path to be passed as nested JSON objects,
        # with the actual command as a value in the bottom object.
        msg = {}
        temp = msg
        for item in path.split(" "):
            temp = temp.setdefault(item, {})
        temp["__" + action + "__"] = cmd
        temp['__INTERFACE__'] = interface

        # cmd_name if defined is used to send a protocol buffers form
        # of the command.
        if (cmd_name is not None):
            import base64
            import google.protobuf
            import vyatta.proto.DataplaneEnvelope_pb2
            import vyatta.proto.VPlanedEnvelope_pb2

            # Build up the Dataplane Envelope here
            de = vyatta.proto.DataplaneEnvelope_pb2.DataplaneEnvelope()
            de.type = cmd_name
            de.msg = cmd.SerializeToString()
            
            # Build up the VPlaned Envelope here
            ve = vyatta.proto.VPlanedEnvelope_pb2.VPlanedEnvelope()
            ve.key = path
            ve.interface = interface
            
            if (action == "SET"):
                ve.action = vyatta.proto.VPlanedEnvelope_pb2.VPlanedEnvelope.SET
            else:
                ve.action = vyatta.proto.VPlanedEnvelope_pb2.VPlanedEnvelope.DELETE
                
            ve.msg = de.SerializeToString()

            # Convert to base64
            temp["__PROTOBUF__"] = base64.b64encode(ve.SerializeToString())
        
        self._store_socket.send_json(msg)
        rc = self._store_socket.recv_string()
        if rc != "OK":
            raise ControllerException("Config {} returned {}".format(msg, rc))

    def config(self, cmd):
        self._cfg_socket.send_multipart(cmd)
        rc = self._cfg_socket.recv_string()
        if rc != "OK":
            raise ControllerException("Config cmd returned {}".format(rc))
