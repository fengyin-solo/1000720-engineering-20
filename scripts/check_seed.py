#!/usr/bin/env python3
"""示例数据离线校验：不起服务就能确认养护计划与养护对象等种子数据可用。

用法：python3 scripts/check_seed.py [backend_dir]

退出码：0 = 校验通过；1 = 数据有问题（原因打印到标准输出）。
这个脚本只依赖标准库，直接从 backend/app 下导入种子数据，不要求先装后端依赖。
"""
from __future__ import annotations

import sys
from pathlib import Path

# 业务模块 -> (中文名称, 每条记录必须有值的关键字段)
EXPECTED_MODULES: dict[str, tuple[str, list[str]]] = {
    "plan": ("养护计划", ["计划编号", "养护类型", "养护对象"]),
    "road": ("道路设施（养护对象）", ["设施编码", "道路名称"]),
    "bridge": ("桥梁设施（养护对象）", ["桥梁编码", "桥梁名称"]),
    "tunnel": ("隧道设施（养护对象）", ["隧道编码", "隧道名称"]),
}

# 每个模块至少应该有的示例条数
MIN_ROWS = 1


def main() -> int:
    backend_dir = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent / "backend"
    if not (backend_dir / "app" / "seed.py").exists():
        print(f"[失败] 找不到后端目录：{backend_dir}/app/seed.py 不存在")
        return 1

    sys.path.insert(0, str(backend_dir))
    try:
        from app.seed import SEED_ROWS  # noqa: E402
    except Exception as exc:  # 示例数据本身有语法/导入问题时要能看出来
        print(f"[失败] 示例数据加载异常：{type(exc).__name__}: {exc}")
        return 1

    errors: list[str] = []

    # 1) routers 目录下每个业务模块都要有种子表（只扫文件名，不导入路由层，
    #    这样在安装后端依赖之前也能跑这个检查）
    routers_dir = backend_dir / "app" / "routers"
    router_names = sorted(p.stem for p in routers_dir.glob("*.py") if p.stem != "__init__")
    for module in router_names:
        if module not in SEED_ROWS:
            errors.append(f"模块 {module} 已注册路由，但 seed.py 里没有示例数据")

    # 2) 关键模块（养护计划 + 养护对象）条数与必填字段
    for module, (label, required_fields) in EXPECTED_MODULES.items():
        rows = SEED_ROWS.get(module)
        if rows is None:
            errors.append(f"{label}（{module}）缺少示例数据")
            continue
        if len(rows) < MIN_ROWS:
            errors.append(f"{label}（{module}）示例数据只有 {len(rows)} 条，至少需要 {MIN_ROWS} 条")
        for index, row in enumerate(rows, start=1):
            for field in required_fields:
                value = row.get(field)
                if value is None or (isinstance(value, str) and not value.strip()):
                    errors.append(f"{label}（{module}）第 {index} 条记录的字段「{field}」为空")

    print(f"示例数据模块数：{len(SEED_ROWS)}（路由模块 {len(router_names)} 个），总记录数：{sum(len(v) for v in SEED_ROWS.values())}")
    for module, (label, _fields) in EXPECTED_MODULES.items():
        print(f"  - {label}: {len(SEED_ROWS.get(module, []))} 条")

    if errors:
        print("[失败] 示例数据校验未通过：")
        for err in errors:
            print(f"  * {err}")
        return 1

    print("[通过] 养护计划与道路/桥梁/隧道等养护对象的示例数据齐全")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
