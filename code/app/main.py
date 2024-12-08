from azure.servicebus import ServiceBusClient
from azure.identity import DefaultAzureCredential
import time
import os

QUEUE_NAME = "scaling-queue"
SERVICEBUS_NAMESPACE = "k8s-scaling-demo-sb-01.servicebus.windows.net"
HOSTNAME = os.getenv("HOSTNAME")

def receive_messages():
    with ServiceBusClient(SERVICEBUS_NAMESPACE, DefaultAzureCredential()) as sb_client:
        with sb_client.get_queue_receiver(QUEUE_NAME) as queue_receiver:
                print(f"Successfully connected to and listening for messages from queue {QUEUE_NAME}")
                while True:
                     for message in queue_receiver.receive_messages(max_message_count=5, max_wait_time=5):
                          print(f"Pod {HOSTNAME} received new message #{message.sequence_number}: {str(message)}, beginning processing")
                          time.sleep(5)
                          print(f"Pod {HOSTNAME} processed message #{message.sequence_number}")
                          queue_receiver.complete_message(message)

if __name__ == "__main__":
    try:
          receive_messages()
    except Exception as exception:
        print(f"Exception raised while listening to messages: {repr(exception)}")

