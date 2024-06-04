import json
from web3 import Web3

# Replace with your Infura project ID or your local node URL
infura_url = "https://eth-mainnet.g.alchemy.com/v2/GWBlcyYZH65PHOKw_l-9pvqYdwJFPo4-"
web3 = Web3(Web3.HTTPProvider(infura_url))

# Check if connected to Ethereum node
if web3.is_connected():
    print("Connected to Ethereum node")
else:
    print("Failed to connect to Ethereum node")
    exit()

# Replace with your contract address and ABI
contract_address = "0x8668a15b7b023Dc77B372a740FCb8939E15257Cf"  # afcvx

# Load the contract ABI from a JSON file
with open('contract_abi.json', 'r') as abi_file:
    contract_abi = json.load(abi_file)

# Create contract instance
contract = web3.eth.contract(address=contract_address, abi=contract_abi)

# Event name to filter
event_name = "UnlockRequested"

# Get the event object
event = getattr(contract.events, event_name)

# Filter parameters (optional)
from_block = 0
to_block = 'latest'

# Fetch events
events = event.create_filter(fromBlock=from_block, toBlock=to_block).get_all_entries()

# Process and display events
receiver_addresses = set()
for e in events:
    receiver_addresses.add(e['args']['receiver'])
    print(f"Event: {e['event']}")
    print(f"Args: {e['args']}")
    print(f"Transaction Hash: {e['transactionHash'].hex()}")
    print(f"Block Number: {e['blockNumber']}\n")

# Print the list of all unique _receiver addresses
print("List of all unique _receiver addresses:")
print(list(receiver_addresses))
