// The agent skill as a zip (public/skills/opentraffic → dist/skills/opentraffic.zip), for downloading.
import { execFileSync } from 'node:child_process'
import { rmSync } from 'node:fs'

rmSync('dist/skills/opentraffic.zip', { force: true })
execFileSync('zip', ['-q', '-r', '-X', '../../dist/skills/opentraffic.zip', 'opentraffic', '-x', '*.DS_Store'], { cwd: 'public/skills' })
console.log('Packaged the agent skill as skills/opentraffic.zip.')
