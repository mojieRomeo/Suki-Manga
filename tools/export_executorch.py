"""Export original trained detectors. Failure is recorded, never replaced with demo weights."""
import os,sys,json,time,traceback,hashlib
from pathlib import Path
root=Path(__file__).resolve().parents[1]
out=root/'models';out.mkdir(exist_ok=True)
source=root/'models/source/model'
os.environ['YOLO_AUTOINSTALL']='false'
os.environ['YOLO_CONFIG_DIR']=str(root/'tools/yolo-settings')
import torch
from executorch.exir import to_edge_transform_and_lower
from executorch.backends.xnnpack.partition.xnnpack_partitioner import XnnpackPartitioner
torch.set_num_threads(4)
(root/'reports').mkdir(exist_ok=True)
report={}
def export(name,module,args):
    start=time.time();module.eval()
    with torch.no_grad():
        reference=module(*args)
        captured=torch.export.export(module,args,strict=False)
        portable=to_edge_transform_and_lower(captured,partitioner=[XnnpackPartitioner()]).to_executorch()
        target=out/(name+'.pte');target.write_bytes(portable.buffer)
    from executorch.extension.pybindings.portable_lib import _load_for_executorch
    runtime=_load_for_executorch(str(target))
    actual=runtime.forward(args)
    differences=[float((a-b).abs().max()) for a,b in zip(actual,reference)]
    for a,b in zip(actual,reference):
        torch.testing.assert_close(a,b,rtol=0.003,atol=0.003)
    report[name]={'ok':True,'numerical_check':True,'max_abs_error':differences,'bytes':target.stat().st_size,'sha256':hashlib.sha256(target.read_bytes()).hexdigest(),'seconds':time.time()-start,'outputs':[list(t.shape) for t in reference]}
try:
    from ultralytics import YOLO
    model=YOLO(str(source/'bubble-seg.pt')).model.eval().fuse()
    head=model.model[-1];head.export=True;head.format='executorch';head.dynamic=False
    export('bubbles',model,(torch.rand(1,3,640,640),))
except Exception:
    report['bubbles']={'ok':False,'error':traceback.format_exc()};print(report['bubbles']['error'],flush=True)
try:
    sys.path.insert(0,str(source.parent))
    from model.configuration_magi import MagiConfig
    from model.modelling_magi import MagiModel
    from safetensors.torch import load_file
    config=json.loads((source/'config.json').read_text());config.update(disable_ocr=True,disable_crop_embeddings=True)
    config=MagiConfig(**config);config.detection_model_config.use_pretrained_backbone=False
    model=MagiModel(config);missing=model.load_state_dict(load_file(str(source/'model.safetensors')),strict=False)
    if missing.unexpected_keys or any(not k.startswith(('character_character_matching_head.','text_character_matching_head.')) for k in missing.missing_keys):raise RuntimeError(str(missing))
    class Detector(torch.nn.Module):
        def __init__(self,m):super().__init__();self.m=m
        def forward(self,pixels,mask):
            output=self.m._get_detection_transformer_output(pixels,mask)
            classes,boxes=self.m._get_predicted_bboxes_and_classes(output)
            dialogue=self.m.is_this_text_a_dialogue(self.m._get_predicted_obj_tokens(output)).sigmoid()
            return classes.sigmoid(),boxes,dialogue
    export('magi',Detector(model),(torch.rand(1,3,1136,800),torch.ones(1,1136,800,dtype=torch.long)))
except Exception:
    report['magi']={'ok':False,'error':traceback.format_exc()};print(report['magi']['error'],flush=True)
report['torch']=torch.__version__
(root/'reports/export-executorch.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
print(json.dumps(report,indent=2),flush=True)
