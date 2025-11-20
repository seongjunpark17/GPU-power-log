import time
import torch
import sys

def main():
    if not torch.cuda.is_available():
        sys.exit(1)

    n_gpus = torch.cuda.device_count()

    # --- Configuration ---
    tensor_size = 10000
    iterations = 200

    time.sleep(5)
    tensors = []
    for i in range(min(2, n_gpus)):
        device = torch.device(f"cuda:{i}")
        a = torch.randn(tensor_size, tensor_size, device=device)
        b = torch.randn(tensor_size, tensor_size, device=device)
        tensors.append((device, a, b))

    # Start measuring
    print("__BEGIN_MEASURE__", flush=True)
    for step in range(iterations):
        for device, a, b in tensors:
            c = torch.matmul(a, b)
            torch.cuda.synchronize(device)
            del c
        print(f"step {step+1}", flush=True)

    # End measuring
    print("__END_MEASURE__", flush=True)

if __name__ == "__main__":
    main()

    