import Foundation

// MARK: - C Type Representation

/// Represents a C type. Uses indirect cases for recursive types (pointers, arrays, functions).
public indirect enum CType: Equatable, Hashable, Sendable {
    case void
    case bool
    case char      // plain char (signedness implementation-defined; we treat as signed)
    case schar     // signed char
    case uchar     // unsigned char
    case short
    case ushort
    case int
    case uint
    case long
    case ulong
    case longLong
    case ulongLong
    case int128      // __int128 (signed)
    case uint128     // unsigned __int128
    case float
    case double
    case longDouble  // approximated as double on ARM64
    case complexFloat    // _Complex float
    case complexDouble   // _Complex double
    case complexLongDouble // _Complex long double (approximated as complex double)
    case complexChar      // _Complex char (2 × char = 2 bytes)
    case complexSchar     // _Complex signed char
    case complexUchar     // _Complex unsigned char
    case complexShort     // _Complex short
    case complexUshort    // _Complex unsigned short
    case complexInt       // _Complex int
    case complexUint      // _Complex unsigned int
    case complexLong      // _Complex long
    case complexUlong     // _Complex unsigned long
    case complexLongLong  // _Complex long long
    case complexUlongLong // _Complex unsigned long long
    case pointer(to: CType)
    case array(of: CType, count: Int)
    case incompleteArray(of: CType)
    case vector(of: CType, count: Int)  // GCC __attribute__((vector_size(N))) — like array but with vector semantics
    case function(params: [CType], returnType: CType, variadic: Bool)
    case structType(RecordType)
    case unionType(RecordType)
    case enumType(EnumType)
    case typedef(name: String, base: CType)

    /// Type qualifiers applied via a wrapper.
    case qualified(base: CType, const: Bool, volatile: Bool, restrict: Bool)

    // MARK: - Properties

    /// True if this is an integer type (including bool and char).
    public var isInteger: Bool {
        switch self {
        case .bool, .char, .schar, .uchar, .short, .ushort, .int, .uint,
             .long, .ulong, .longLong, .ulongLong, .int128, .uint128:
            return true
        case .qualified(let base, _, _, _):
            return base.isInteger
        case .typedef(_, let base):
            return base.isInteger
        default:
            return false
        }
    }

    public var isFloating: Bool {
        switch self {
        case .float, .double, .longDouble,
             .complexFloat, .complexDouble, .complexLongDouble:
            return true
        case .qualified(let base, _, _, _):
            return base.isFloating
        case .typedef(_, let base):
            return base.isFloating
        default:
            return false
        }
    }

    public var isArithmetic: Bool {
        return isInteger || isFloating || isComplex
    }

    /// True for 32-bit signed integer types that need sxtw before 64-bit arithmetic.
    /// These types are loaded with ldr wN (zero-extended) but need sign extension
    /// for correct 64-bit operations (e.g., array indexing with negative values).
    public var isSigned32Bit: Bool {
        switch self {
        case .int, .short, .schar, .char, .enumType:
            return true
        case .qualified(let base, _, _, _):
            return base.isSigned32Bit
        case .typedef(_, let base):
            return base.isSigned32Bit
        default:
            return false
        }
    }

    public var isChar: Bool {
        switch self {
        case .char, .schar, .uchar: return true
        case .qualified(let base, _, _, _): return base.isChar
        case .typedef(_, let base): return base.isChar
        default: return false
        }
    }

    /// True for unsigned integer types.
    public var isUnsigned: Bool {
        switch self {
        case .bool, .uchar, .ushort, .uint, .ulong, .ulongLong, .uint128: return true
        case .qualified(let base, _, _, _): return base.isUnsigned
        case .typedef(_, let base): return base.isUnsigned
        default: return false
        }
    }

    public var isScalar: Bool {
        return isArithmetic || isPointer
    }

    /// True for complex types (both floating and integer).
    public var isComplex: Bool {
        switch self {
        case .complexFloat, .complexDouble, .complexLongDouble,
             .complexChar, .complexSchar, .complexUchar,
             .complexShort, .complexUshort,
             .complexInt, .complexUint,
             .complexLong, .complexUlong,
             .complexLongLong, .complexUlongLong:
            return true
        case .qualified(let base, _, _, _):
            return base.isComplex
        case .typedef(_, let base):
            return base.isComplex
        default:
            return false
        }
    }

    /// For complex types, the corresponding real type.
    public var complexRealType: CType {
        switch self {
        case .complexFloat: return .float
        case .complexDouble: return .double
        case .complexLongDouble: return .longDouble
        case .complexChar: return .char
        case .complexSchar: return .schar
        case .complexUchar: return .uchar
        case .complexShort: return .short
        case .complexUshort: return .ushort
        case .complexInt: return .int
        case .complexUint: return .uint
        case .complexLong: return .long
        case .complexUlong: return .ulong
        case .complexLongLong: return .longLong
        case .complexUlongLong: return .ulongLong
        case .qualified(let base, _, _, _):
            return base.complexRealType
        case .typedef(_, let base):
            return base.complexRealType
        default:
            return self
        }
    }

    public var isPointer: Bool {
        switch self {
        case .pointer: return true
        case .qualified(let base, _, _, _): return base.isPointer
        case .typedef(_, let base): return base.isPointer
        default: return false
        }
    }

    public var isVoid: Bool {
        switch self {
        case .void: return true
        case .qualified(let base, _, _, _): return base.isVoid
        case .typedef(_, let base): return base.isVoid
        default: return false
        }
    }

    public var isFunction: Bool {
        switch self {
        case .function: return true
        case .qualified(let base, _, _, _): return base.isFunction
        case .typedef(_, let base): return base.isFunction
        default: return false
        }
    }

    public var isArray: Bool {
        switch self {
        case .array: return true
        case .incompleteArray: return true
        case .vector: return true  // vector is array-like
        case .qualified(let base, _, _, _): return base.isArray
        case .typedef(_, let base): return base.isArray
        default: return false
        }
    }

    public var isStruct: Bool {
        switch self {
        case .structType: return true
        case .qualified(let base, _, _, _): return base.isStruct
        case .typedef(_, let base): return base.isStruct
        default: return false
        }
    }

    public var isUnion: Bool {
        switch self {
        case .unionType: return true
        case .qualified(let base, _, _, _): return base.isUnion
        case .typedef(_, let base): return base.isUnion
        default: return false
        }
    }

    public var isEnum: Bool {
        switch self {
        case .enumType: return true
        case .qualified(let base, _, _, _): return base.isEnum
        case .typedef(_, let base): return base.isEnum
        default: return false
        }
    }

    /// Strip typedefs and qualifiers to get the underlying type.
    public var unqualified: CType {
        switch self {
        case .qualified(let base, _, _, _):
            return base.unqualified
        case .typedef(_, let base):
            return base.unqualified
        default:
            return self
        }
    }

    /// Strip only qualifiers (not typedefs).
    public var stripQualifiers: CType {
        switch self {
        case .qualified(let base, _, _, _):
            return base.stripQualifiers
        default:
            return self
        }
    }

    /// Size in bytes on ARM64 (LP64). Returns nil for incomplete types.
    public var sizeInBytes: Int? {
        switch self {
        case .void:
            return 1  // void has size 1 for pointer arithmetic purposes
        case .bool:
            return 1
        case .char, .schar, .uchar:
            return 1
        case .short, .ushort:
            return 2
        case .int, .uint, .float:
            return 4
        case .long, .ulong, .longLong, .ulongLong, .double, .longDouble:
            return 8
        case .int128, .uint128:
            return 16
        case .complexFloat:
            return 8   // 2 × float
        case .complexDouble, .complexLongDouble:
            return 16  // 2 × double
        case .complexChar, .complexSchar, .complexUchar:
            return 2   // 2 × char
        case .complexShort, .complexUshort:
            return 4   // 2 × short
        case .complexInt, .complexUint:
            return 8   // 2 × int
        case .complexLong, .complexUlong, .complexLongLong, .complexUlongLong:
            return 16  // 2 × long/longLong
        case .pointer, .function:
            return 8
        case .array(let elem, let count):
            guard let elemSize = elem.sizeInBytes else { return nil }
            // Use overflow-checked multiplication to avoid trap on huge arrays
            // (e.g., 991014-1 has short[~4.6e18] which overflows Int64)
            let (result, overflow) = elemSize.multipliedReportingOverflow(by: count)
            return overflow ? Int.max : result
        case .vector(let elem, let count):
            guard let elemSize = elem.sizeInBytes else { return nil }
            return elemSize * count
        case .incompleteArray:
            return nil
        case .structType(let rec), .unionType(let rec):
            return rec.size
        case .enumType:
            return 4  // enums are int-sized
        case .qualified(let base, _, _, _):
            return base.sizeInBytes
        case .typedef(_, let base):
            return base.sizeInBytes
        }
    }

    /// Alignment in bytes on ARM64.
    public var alignOf: Int? {
        switch self {
        case .void:
            return 1
        case .bool, .char, .schar, .uchar:
            return 1
        case .short, .ushort:
            return 2
        case .int, .uint, .float:
            return 4
        case .long, .ulong, .longLong, .ulongLong, .double, .longDouble:
            return 8
        case .int128, .uint128:
            return 16
        case .complexFloat:
            return 4   // aligned to float
        case .complexDouble, .complexLongDouble:
            return 8  // aligned to double
        case .complexChar, .complexSchar, .complexUchar:
            return 1
        case .complexShort, .complexUshort:
            return 2
        case .complexInt, .complexUint:
            return 4
        case .complexLong, .complexUlong, .complexLongLong, .complexUlongLong:
            return 8
        case .pointer, .function:
            return 8
        case .array(let elem, _):
            return elem.alignOf
        case .vector(let elem, _):
            return elem.alignOf
        case .incompleteArray(let elem):
            return elem.alignOf
        case .structType(let rec):
            return rec.alignment
        case .unionType(let rec):
            return rec.alignment
        case .enumType:
            return 4
        case .qualified(let base, _, _, _):
            return base.alignOf
        case .typedef(_, let base):
            return base.alignOf
        }
    }

    /// Is this a signed integer type?
    public var isSigned: Bool {
        switch self {
        case .char, .schar, .short, .int, .long, .longLong, .int128:
            return true
        case .bool, .uchar, .ushort, .uint, .ulong, .ulongLong:
            return false
        case .qualified(let base, _, _, _):
            return base.isSigned
        case .typedef(_, let base):
            return base.isSigned
        default:
            return false
        }
    }

    /// Whether this type is const-qualified.
    public var isConst: Bool {
        if case .qualified(_, let c, _, _) = self { return c }
        return false
    }
}

// MARK: - Record Type (struct/union)

/// Represents a struct or union's layout.
public final class RecordType: Equatable, Hashable, @unchecked Sendable {
    public let name: String
    public var fields: [RecordField]
    public var size: Int?        // nil if incomplete
    public var alignment: Int?   // nil if incomplete

    public init(name: String, fields: [RecordField] = [], size: Int? = nil, alignment: Int? = nil) {
        self.name = name
        self.fields = fields
        self.size = size
        self.alignment = alignment
    }

    public static func == (lhs: RecordType, rhs: RecordType) -> Bool {
        return lhs === rhs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

/// A field within a struct or union.
public struct RecordField: Equatable, Sendable {
    public let name: String?
    public let type: CType
    public let bitWidth: Int?    // nil = normal field; Int = bitfield width
    public let offset: Int       // byte offset within the record
    public let bitOffset: Int    // bit offset within the containing allocation unit (for bitfields)

    public init(name: String?, type: CType, bitWidth: Int? = nil, offset: Int = 0, bitOffset: Int = 0) {
        self.name = name
        self.type = type
        self.bitWidth = bitWidth
        self.offset = offset
        self.bitOffset = bitOffset
    }
}

// MARK: - Enum Type

public final class EnumType: Equatable, Hashable, @unchecked Sendable {
    public let name: String
    public var cases: [EnumCase]
    public var underlyingType: CType  // typically .int

    public init(name: String, cases: [EnumCase] = [], underlyingType: CType = .int) {
        self.name = name
        self.cases = cases
        self.underlyingType = underlyingType
    }

    public static func == (lhs: EnumType, rhs: EnumType) -> Bool {
        return lhs === rhs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

/// An enumerator constant within an enum.
public struct EnumCase: Equatable, Sendable {
    public let name: String
    public let value: Int

    public init(name: String, value: Int) {
        self.name = name
        self.value = value
    }
}
