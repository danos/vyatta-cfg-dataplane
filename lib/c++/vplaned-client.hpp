#ifndef __VPLANED_HPP__
#define __VPLANED_HPP__

#include <string>
#include <vector>
#include <exception>

#include <zmq.hpp>
#include <google/protobuf/message.h>
#include <VPlanedEnvelope.pb.h>
#include <DataplaneEnvelope.pb.h>

namespace vplaned {
	class ControllerException: public std::exception {
	public:
		ControllerException(std::string msg);
		virtual ~ControllerException();
		virtual const char* what() const throw();
	private:
		std::string _msg;
	};

	class Controller {
	public:
		Controller(const std::string store_endpoint="ipc:///var/run/vyatta/vplaned.socket",
				   const std::string cfg_endpoint="ipc:///var/run/vyatta/vplaned-config.socket");
		virtual ~Controller();

		void store(const std::string path,
				   const std::string msg_type,
				   const ::google::protobuf::Message &msg,
				   const std::string interface = "");

		void store(const std::string action,
				   const std::string path,
				   const std::string msg_type,
				   const ::google::protobuf::Message &msg,
				   const std::string interface = "");
	private:
		zmq::context_t _ctx;
		zmq::socket_t *_store_socket;
		zmq::socket_t *_config_socket;
		std::string _store_endpoint;
		std::string _config_endpoint;
	};
}

#endif
