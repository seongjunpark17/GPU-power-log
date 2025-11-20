import time
import torch
import sys

def main():
    if not torch.cuda.is_available():
        sys.exit(1)

    device = torch.device("cuda:0")

    # --- Configuration ---
    tensor_size = 10000
    iterations = 200

    time.sleep(2)
    a = torch.randn(tensor_size, tensor_size, device=device)
    b = torch.randn(tensor_size, tensor_size, device=device)

    # Start measuring
    print("__BEGIN_MEASURE__",flush=True)
    for step in range(iterations):
        c = torch.matmul(a, b)
        torch.cuda.synchronize() 
        del c
        print(f"step {step+1}", flush=True)

    # End measuring
    print("__END_MEASURE__", flush=True)

if __name__ == "__main__":
    main()
