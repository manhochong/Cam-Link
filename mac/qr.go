package main

// Same QR as the Windows receiver: versions 2–4, ECC M, mask 0, byte mode, up to 62 bytes.
var qrExp [512]byte
var qrLog [256]int
var qrFormatM = []int{0x5412, 0x5125, 0x5e7c, 0x5b4b, 0x45f9, 0x40ce, 0x4f97, 0x4aa0}

func init() {
	x := 1
	for i := 0; i < 255; i++ {
		qrExp[i] = byte(x)
		qrLog[x] = i
		x <<= 1
		if x&0x100 != 0 {
			x ^= 0x11d
		}
	}
	for i := 255; i < 512; i++ {
		qrExp[i] = qrExp[i-255]
	}
}

func qrMul(a, b int) byte {
	if a == 0 || b == 0 {
		return 0
	}
	return qrExp[qrLog[a]+qrLog[b]]
}

func qrGenerator(ecc int) []byte {
	poly := []byte{1}
	for i := 0; i < ecc; i++ {
		next := make([]byte, len(poly)+1)
		for j := 0; j < len(poly); j++ {
			next[j] ^= poly[j]
			next[j+1] ^= qrMul(int(poly[j]), int(qrExp[i]))
		}
		poly = next
	}
	gen := make([]byte, ecc)
	copy(gen, poly[1:1+ecc])
	return gen
}

func qrReedSolomon(data []byte, ecc int) []byte {
	gen := qrGenerator(ecc)
	work := make([]byte, len(data)+ecc)
	copy(work, data)
	for i := 0; i < len(data); i++ {
		coef := int(work[i])
		if coef == 0 {
			continue
		}
		for j := 0; j < ecc; j++ {
			work[i+1+j] ^= qrMul(int(gen[j]), coef)
		}
	}
	out := make([]byte, ecc)
	copy(out, work[len(data):])
	return out
}

func qrAdd(bits []bool, value, count int) []bool {
	for i := count - 1; i >= 0; i-- {
		bits = append(bits, (value>>i)&1 == 1)
	}
	return bits
}

func qrFinder(matrix [][]int, row, col int) {
	for r := 0; r < 7; r++ {
		for c := 0; c < 7; c++ {
			edge := r == 0 || r == 6 || c == 0 || c == 6
			core := r >= 2 && r <= 4 && c >= 2 && c <= 4
			if edge || core {
				matrix[row+r][col+c] = 1
			} else {
				matrix[row+r][col+c] = 0
			}
		}
	}
	size := len(matrix)
	for i := -1; i <= 7; i++ {
		if row+i >= 0 && row+i < size {
			if col-1 >= 0 {
				matrix[row+i][col-1] = 0
			}
			if col+7 < size {
				matrix[row+i][col+7] = 0
			}
		}
		if col+i >= 0 && col+i < size {
			if row-1 >= 0 {
				matrix[row-1][col+i] = 0
			}
			if row+7 < size {
				matrix[row+7][col+i] = 0
			}
		}
	}
}

func qrModules(text string) [][]bool {
	raw := []byte(text)
	version := 2
	if len(raw) > 26 {
		version = 3
	}
	if len(raw) > 42 {
		version = 4
	}
	if len(raw) > 62 {
		return nil
	}
	blocks, dataLen, eccLen := 1, 28, 16
	if version == 3 {
		dataLen, eccLen = 44, 26
	}
	if version == 4 {
		blocks, dataLen, eccLen = 2, 32, 18
	}
	bits := qrAdd(nil, 0x4, 4)
	bits = qrAdd(bits, len(raw), 8)
	for _, b := range raw {
		bits = qrAdd(bits, int(b), 8)
	}
	capacity := blocks * dataLen * 8
	for i := 0; i < 4 && len(bits) < capacity; i++ {
		bits = append(bits, false)
	}
	for len(bits)%8 != 0 {
		bits = append(bits, false)
	}
	data := make([]byte, blocks*dataLen)
	for i := 0; i < len(bits)/8; i++ {
		v := 0
		for b := 0; b < 8; b++ {
			if bits[i*8+b] {
				v |= 1 << (7 - b)
			}
		}
		data[i] = byte(v)
	}
	for i, pad := len(bits)/8, 0; i < len(data); i, pad = i+1, pad+1 {
		if pad%2 == 0 {
			data[i] = 0xEC
		} else {
			data[i] = 0x11
		}
	}
	var message []byte
	ecc := make([][]byte, blocks)
	for b := 0; b < blocks; b++ {
		block := make([]byte, dataLen)
		copy(block, data[b*dataLen:(b+1)*dataLen])
		ecc[b] = qrReedSolomon(block, eccLen)
	}
	for i := 0; i < dataLen; i++ {
		for b := 0; b < blocks; b++ {
			message = append(message, data[b*dataLen+i])
		}
	}
	for i := 0; i < eccLen; i++ {
		for b := 0; b < blocks; b++ {
			message = append(message, ecc[b][i])
		}
	}
	stream := make([]bool, 0, len(message)*8+7)
	for _, b := range message {
		stream = qrAdd(stream, int(b), 8)
	}
	for i := 0; i < 7; i++ {
		stream = append(stream, false)
	}
	size := 17 + version*4
	matrix := make([][]int, size)
	for r := 0; r < size; r++ {
		matrix[r] = make([]int, size)
		for c := 0; c < size; c++ {
			matrix[r][c] = 2
		}
	}
	for i := 0; i < 9; i++ {
		matrix[i][8] = 0
		matrix[8][i] = 0
	}
	for i := 0; i < 8; i++ {
		matrix[size-1-i][8] = 0
		matrix[8][size-1-i] = 0
	}
	bit := 1
	for i := 8; i < size-8; i++ {
		matrix[6][i] = bit
		matrix[i][6] = bit
		bit ^= 1
	}
	qrFinder(matrix, 0, 0)
	qrFinder(matrix, 0, size-7)
	qrFinder(matrix, size-7, 0)
	align := []int{6, 18}
	if version == 3 {
		align = []int{6, 22}
	}
	if version == 4 {
		align = []int{6, 26}
	}
	for _, y := range align {
		for _, x := range align {
			if (x == 6 && y == 6) || (x == 6 && y == align[len(align)-1]) || (y == 6 && x == align[len(align)-1]) {
				continue
			}
			for dy := -2; dy <= 2; dy++ {
				for dx := -2; dx <= 2; dx++ {
					if max(abs(dx), abs(dy)) != 1 {
						matrix[y+dy][x+dx] = 1
					} else {
						matrix[y+dy][x+dx] = 0
					}
				}
			}
		}
	}
	region := make([][]bool, size)
	for r := 0; r < size; r++ {
		region[r] = make([]bool, size)
		for c := 0; c < size; c++ {
			region[r][c] = matrix[r][c] == 2
		}
	}
	idx := 0
	for step := size - 1; step > 0; step -= 2 {
		right := step
		if right <= 6 {
			right--
		}
		for vertical := 0; vertical < size; vertical++ {
			for z := 0; z < 2; z++ {
				col := right - z
				up := ((right & 2) == 0) != (col < 6)
				row := vertical
				if up {
					row = size - 1 - vertical
				}
				if matrix[row][col] == 2 && idx < len(stream) {
					if stream[idx] {
						matrix[row][col] = 1
					} else {
						matrix[row][col] = 0
					}
					idx++
				}
			}
		}
	}
	if idx != len(stream) {
		return nil
	}
	for r := 0; r < size; r++ {
		for c := 0; c < size; c++ {
			if !region[r][c] {
				continue
			}
			if matrix[r][c] == 2 {
				matrix[r][c] = 0
			}
			if (r+c)&1 == 0 {
				matrix[r][c] ^= 1
			}
		}
	}
	format := qrFormatM[0]
	vOff, hOff := 0, 0
	for i := 0; i < 8; i++ {
		vbit := (format >> i) & 1
		hbit := (format >> (14 - i)) & 1
		if i == 6 {
			vOff++
			hOff = 1
		}
		matrix[i+vOff][8] = vbit
		matrix[8][i+hOff] = hbit
		matrix[8][size-1-i] = vbit
		matrix[size-1-i][8] = hbit
	}
	matrix[size-8][8] = 1
	modules := make([][]bool, size)
	for r := 0; r < size; r++ {
		modules[r] = make([]bool, size)
		for c := 0; c < size; c++ {
			modules[r][c] = matrix[r][c] == 1
		}
	}
	return modules
}

func abs(v int) int {
	if v < 0 {
		return -v
	}
	return v
}
