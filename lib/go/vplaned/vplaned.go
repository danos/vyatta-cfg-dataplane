// Copyright (c) 2020 , AT&T Intellectual Property. All rights reserved.
// SPDX-License-Identifier: MPL-2.0

package vplaned

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"runtime"
	"strings"
	"sync"

	"github.com/danos/vyatta-controller/protobuf/go/VPlanedEnvelope"
	"github.com/danos/vyatta-dataplane/protobuf/go/DataplaneEnvelope"
	"github.com/golang/protobuf/proto"
	zmq "github.com/zeromq/goczmq"
)

const (
	storeEndpoint  = "ipc:///var/run/vyatta/vplaned.socket"
	configEndpoint = "ipc:///var/run/vyatta/vplaned-config.socket"
)

type Error string

func (e Error) Error() string {
	return string(e)
}

const (
	ErrNoControllerResponse = Error("No response from controller")
	ErrConfigStoreFailed = Error("Config store failed")
	ErrNoCommitAction = Error("COMMIT_ACTION not found")
)

type Conn struct {
	mu sync.RWMutex

	storeEndpoint, configEndpoint string
	configSocket, storeSocket     *zmq.Sock
}

type dialOpt func(*Conn)

func ConfigEndpoint(address string) dialOpt {
	return func(c *Conn) {
		c.configEndpoint = address
	}
}

func StoreEndpoint(address string) dialOpt {
	return func(c *Conn) {
		c.storeEndpoint = address
	}
}

func Dial(opts ...dialOpt) (*Conn, error) {
	out := Conn{
		storeEndpoint:  storeEndpoint,
		configEndpoint: configEndpoint,
	}
	for _, opt := range opts {
		opt(&out)
	}
	storeSock, err := zmq.NewReq(
		out.storeEndpoint,
		zmq.SockSetLinger(0),
		zmq.SockSetRcvtimeo(10000),
		zmq.SockSetIpv6(1),
	)
	if err != nil {
		return nil, err
	}
	confSock, err := zmq.NewReq(
		out.configEndpoint,
		zmq.SockSetLinger(0),
		zmq.SockSetRcvtimeo(10000),
		zmq.SockSetIpv6(1),
	)
	if err != nil {
		return nil, err
	}

	out.storeSocket = storeSock
	out.configSocket = confSock
	runtime.SetFinalizer(&out, func(c *Conn) {
		c.Close()
	})
	return &out, nil
}

func (c *Conn) Close() error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.storeSocket == nil || c.configSocket == nil {
		return nil
	}
	err := c.storeSocket.Disconnect(c.storeEndpoint)
	if err != nil {
		return err
	}
	err = c.configSocket.Disconnect(c.configEndpoint)
	if err != nil {
		return err
	}
	c.storeSocket.Destroy()
	c.configSocket.Destroy()
	c.storeSocket = nil
	c.configSocket = nil
	return nil
}

func (c *Conn) Store(
	path, msgType string,
	msg proto.Message,
	opts ...storeOpt,
) error {
	c.mu.RLock()
	defer c.mu.RUnlock()

	storeOpts := storeOptions{}
	for _, opt := range opts {
		opt(&storeOpts)
	}
	if storeOpts.action == "" {
		storeOpts.action = os.Getenv("COMMIT_ACTION")
	}

	if storeOpts.action == "" {
		return ErrNoCommitAction
	}

	msgData, err := proto.Marshal(msg)
	if err != nil {
		return err
	}

	de := DataplaneEnvelope.DataplaneEnvelope{
		Type: proto.String(msgType),
		Msg:  msgData,
	}

	deData, err := proto.Marshal(&de)
	if err != nil {
		return err
	}

	vpe := VPlanedEnvelope.VPlanedEnvelope{
		Key: proto.String(path),
		Msg: deData,
	}
	if storeOpts.iface != "" {
		vpe.Interface = proto.String(storeOpts.iface)
	}
	if storeOpts.action == "SET" {
		vpe.Action = VPlanedEnvelope.VPlanedEnvelope_SET.Enum()
	} else {
		vpe.Action = VPlanedEnvelope.VPlanedEnvelope_DELETE.Enum()
	}
	vpeData, err := proto.Marshal(&vpe)
	if err != nil {
		return err
	}

	cmd := "protobuf " + base64.StdEncoding.EncodeToString(vpeData)

	jobj := make(map[string]interface{})
	tmp := jobj
	for _, elem := range strings.Split(path, " ") {
		obj := make(map[string]interface{})
		tmp[elem] = obj
		tmp = obj
	}
	tmp["__"+storeOpts.action+"__"] = cmd
	if storeOpts.iface != "" {
		tmp["__INTERFACE__"] = storeOpts.iface
	}
	tmp["__PROTOBUF__"] = true

	encodedMsg, err := json.Marshal(jobj)
	if err != nil {
		return err
	}

	err = c.storeSocket.SendMessage([][]byte{encodedMsg})
	if err != nil {
		return err
	}
	zmsg, err := c.storeSocket.RecvMessage()
	if err != nil {
		return err
	}
	if len(zmsg) == 0 {
		return ErrNoControllerResponse
	}
	if string(zmsg[0]) != "OK" {
		return ErrConfigStoreFailed
	}
	return nil
}

type storeOpt func(*storeOptions)
type storeOptions struct {
	action, iface string
}

func Action(action string) storeOpt {
	return func(o *storeOptions) {
		o.action = action
	}
}

func Interface(iface string) storeOpt {
	return func(o *storeOptions) {
		o.iface = iface
	}
}
