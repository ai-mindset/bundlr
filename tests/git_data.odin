package acceptance

GIT_APPLICATION :: `import os
import sys
import subprocess
from pathlib import Path

def main():
    assert Path(sys.argv[0]).name == 'git-demo', sys.argv
    assert Path(sys.argv[0]).parent == Path(__file__).parent.parent, sys.argv
    assert sys.argv[1:] == ['literal spaces; $(safe)', 'quoted "value"'], sys.argv
    import packaging
    if sys.platform == 'win32':
        import colorama
        assert colorama.__version__ == '0.4.6'
    assert packaging.__version__ == '24.2'
    if sys.platform != 'win32':
        subprocess.run([str(Path(__file__).with_name('packaged-helper'))], check=True)
    print('Bundlr Git acceptance: ' + sys.platform)
    return 0

def window():
    assert Path(sys.argv[0]).name == 'git-window', sys.argv
    assert Path(sys.argv[0]).parent == Path(__file__).parent.parent, sys.argv
    assert sys.argv[1:] == [], sys.argv
    import tkinter
    root = tkinter.Tk()
    root.title('Bundlr GUI acceptance')
    tkinter.Label(root, text='Bundlr GUI acceptance').pack()
    def complete():
        Path(os.environ['BUNDLR_GUI_MARKER']).write_text('tkinter event loop passed')
        root.destroy()
    root.after(100, complete)
    root.mainloop()
    return 0
`

GIT_BACKEND :: `from pathlib import Path
import base64
import hashlib
import zipfile

def build_wheel(wheel_directory, config_settings=None, metadata_directory=None):
    name = 'bundlr_acceptance-1.0.0-py3-none-any.whl'
    info = 'bundlr_acceptance-1.0.0.dist-info/'
    files = {
        'application.py': Path(__file__).with_name('application.py').read_bytes(),
        'packaged-helper': b'#!/bin/sh\necho "Packaged executable helper passed"\n',
        info + 'METADATA': b'Metadata-Version: 2.3\nName: bundlr-acceptance\nVersion: 1.0.0\nRequires-Python: >=3.12\nRequires-Dist: packaging==24.2\nRequires-Dist: colorama==0.4.6; sys_platform == "win32"\n',
        info + 'WHEEL': b'Wheel-Version: 1.0\nGenerator: bundlr-acceptance\nRoot-Is-Purelib: PURELIB\nTag: py3-none-any\n',
        info + 'entry_points.txt': b'[console_scripts]\ngit-demo = application:main\n[gui_scripts]\ngit-window = application:window\n',
        info + 'LICENSE': b'Bundlr synthetic acceptance fixture.\n',
    }
    record = []
    for path, data in files.items():
        digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b'=').decode()
        record.append(path + ',sha256=' + digest + ',' + str(len(data)))
    files[info + 'RECORD'] = ('\n'.join(record) + '\n' + info + 'RECORD,,\n').encode()
    with zipfile.ZipFile(Path(wheel_directory) / name, 'w') as archive:
        for path, data in files.items():
            item = zipfile.ZipInfo(path)
            item.create_system = 3
            item.external_attr = (0o100755 if path == 'packaged-helper' else 0o100644) << 16
            archive.writestr(item, data)
    return name
`
