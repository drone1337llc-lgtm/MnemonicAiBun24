import time
t0 = time.time()
from mnemonicai.appconfig import AppConfig
from mnemonicai.backend import TransformersPeftBackend

cfg = AppConfig.load(r"C:\Users\Tench\Documents\mnemonicai_project\config.json")
cfg.backend = "transformers"
be = TransformersPeftBackend(cfg)
import torch
print(f"TRAIN_STACK_OK loaded in {time.time()-t0:.0f}s "
      f"vram={torch.cuda.memory_allocated()/1e9:.1f}GB "
      f"trainable={sum(p.numel() for p in be.model.parameters() if p.requires_grad)/1e6:.1f}M params",
      flush=True)
