#include <algorithm>
#include <sstream>
#include <string>
#include <vector>

#include <b64/encode.h>
#include <jansson.h>

#include "vplaned-client.hpp"

vplaned::ControllerException::ControllerException(std::string msg) {
	this->_msg = msg;
}

vplaned::ControllerException::~ControllerException() {}

const char*
vplaned::ControllerException::what() const throw()
{
	return this->_msg.c_str();
}

vplaned::Controller::Controller(
	const std::string store_endpoint,
	const std::string config_endpoint)
{
	int recvtimeo = 10000;
	int linger = 0;
	this->_store_endpoint = store_endpoint;
	this->_config_endpoint = config_endpoint;

	int rc = zmq_ctx_set((void*)this->_ctx, ZMQ_IPV6, 1);
	if (rc < 0) {
		throw vplaned::ControllerException(strerror(errno));
	}

	this->_store_socket = new zmq::socket_t(_ctx, zmq::socket_type::req);
	this->_store_socket->setsockopt(ZMQ_RCVTIMEO, recvtimeo);
	this->_store_socket->setsockopt(ZMQ_LINGER, linger);
	this->_store_socket->connect(this->_store_endpoint);

	this->_config_socket = new zmq::socket_t(_ctx, zmq::socket_type::req);
	this->_config_socket->setsockopt(ZMQ_RCVTIMEO, recvtimeo);
	this->_config_socket->setsockopt(ZMQ_LINGER, linger);
	this->_config_socket->connect(this->_config_endpoint);
}

vplaned::Controller::~Controller() {
	delete this->_store_socket;
	delete this->_config_socket;
}

void
vplaned::Controller::store(
	const std::string path,
	const std::string msg_type,
	const ::google::protobuf::Message &msg,
	const std::string interface)
{
	std::string action = getenv("COMMIT_ACTION");
	this->store(action, path, msg_type, msg, interface);
}

static void
split_string(const std::string str, const std::string delim, std::vector<std::string> &out)
{
	std::string::size_type cur, prev = 0;
	cur = str.find(delim);
	while (cur != std::string::npos) {
		out.push_back(str.substr(prev, cur - prev));
		prev = cur + 1;
		cur = str.find(delim, prev);
	}
	out.push_back(str.substr(prev, cur - prev));
}

static void
_recv_reply(zmq::socket_t *sock, std::vector<zmq::message_t> &out)
{
	std::vector<zmq::pollitem_t> poll_items = {
		{ (void *)(*sock), 0, ZMQ_POLLIN,  0, },
	};
	zmq::poll(poll_items, 10000);

	while (true) {
		zmq::message_t msg;
		if (!sock->recv(&msg)) {
			break;
		}
		out.push_back(std::move(msg));
		int rc = sock->getsockopt<int>(ZMQ_RCVMORE);
		if (rc <= 0) {
			break;
		}
	}
}

void
vplaned::Controller::store(
	const std::string action,
	const std::string path,
	const std::string msg_type,
	const ::google::protobuf::Message &msg,
	const std::string interface)
{
	if (action == "") {
		throw vplaned::ControllerException("COMMIT_ACTION not found.");
	}

	std::string msg_str;
	msg.SerializeToString(&msg_str);

	DataplaneEnvelope de;
	de.set_type(msg_type);
	de.set_msg(msg_str);

	std::string de_str;
	de.SerializeToString(&de_str);

	VPlanedEnvelope vpe;
	vpe.set_key(path);
	if (interface != "") {
		vpe.set_interface(interface);
	}
	if (action == "SET") {
		vpe.set_action(VPlanedEnvelope_Action_SET);
	} else {
		vpe.set_action(VPlanedEnvelope_Action_DELETE);
	}
	vpe.set_msg(de_str);

	std::string vpe_str;
	vpe.SerializeToString(&vpe_str);

	std::istringstream istream(vpe_str);
	std::ostringstream ostream;
	base64::encoder E;
	E.encode(istream, ostream);
	std::string cmd = "protobuf "+ostream.str();

	std::vector<std::string> path_v;
	split_string(path, " ", path_v);

	json_t *jmsg = json_object();
	json_t *temp = jmsg;
	for (auto& item : path_v) {
		json_t *obj = json_object();
		json_object_set_new(temp, item.c_str(), obj);
		temp = obj;
	}

	json_object_set_new(temp, ("__"+action+"__").c_str(),
						json_string(cmd.c_str()));
	if (interface != "") {
		json_object_set_new(temp, "__INTERFACE__",
							json_string(interface.c_str()));
	}
	json_object_set_new(temp, "__PROTOBUF__", json_true());

	char *encoded_msg = json_dumps(jmsg, JSON_COMPACT);
	json_decref(jmsg);

	zmq::message_t zmq_msg(encoded_msg, strlen(encoded_msg));
	this->_store_socket->send(zmq_msg);
	free(encoded_msg);

	std::vector<zmq::message_t> rcvd;
	_recv_reply(this->_store_socket, rcvd);
	if (rcvd.size() == 0) {
		throw vplaned::ControllerException("No response from controller");
	}

	std::string status((char*)rcvd[0].data(), rcvd[0].size());
	if (status != "OK") {
		throw vplaned::ControllerException("Config store failed");
	}
}
