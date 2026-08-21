import XCTest
@testable import CCommon

final class TypeTests: XCTestCase {

    // MARK: - CType construction and equality

    func testBasicTypeEquality() {
        XCTAssertEqual(CType.int, CType.int)
        XCTAssertNotEqual(CType.int, CType.long)
        XCTAssertEqual(CType.pointer(to: .int), CType.pointer(to: .int))
        XCTAssertNotEqual(CType.pointer(to: .int), CType.pointer(to: .char))
    }

    func testQualifiedType() {
        let constInt = CType.qualified(base: .int, const: true, volatile: false, restrict: false)
        XCTAssertTrue(constInt.isConst)
        XCTAssertTrue(constInt.isInteger)
        XCTAssertEqual(constInt.unqualified, .int)
        XCTAssertEqual(constInt.stripQualifiers, .int)
    }

    func testTypedef() {
        let td = CType.typedef(name: "IntPtr", base: .pointer(to: .int))
        XCTAssertTrue(td.isPointer)
        XCTAssertEqual(td.unqualified, .pointer(to: .int))
        XCTAssertEqual(td.sizeInBytes, 8)
    }

    func testArrayType() {
        let arr = CType.array(of: .char, count: 10)
        XCTAssertTrue(arr.isArray)
        XCTAssertEqual(arr.sizeInBytes, 10)
        XCTAssertEqual(arr.alignOf, 1)
    }

    func testFunctionType() {
        let fn = CType.function(params: [.int, .int], returnType: .int, variadic: false)
        XCTAssertTrue(fn.isFunction)
        XCTAssertEqual(fn.sizeInBytes, 8)  // function types have pointer size when decayed
    }

    // MARK: - Type properties

    func testIsInteger() {
        XCTAssertTrue(CType.int.isInteger)
        XCTAssertTrue(CType.char.isInteger)
        XCTAssertTrue(CType.bool.isInteger)
        XCTAssertTrue(CType.longLong.isInteger)
        XCTAssertFalse(CType.float.isInteger)
        XCTAssertFalse(CType.pointer(to: .int).isInteger)
    }

    func testIsFloating() {
        XCTAssertTrue(CType.float.isFloating)
        XCTAssertTrue(CType.double.isFloating)
        XCTAssertFalse(CType.int.isFloating)
    }

    func testIsArithmetic() {
        XCTAssertTrue(CType.int.isArithmetic)
        XCTAssertTrue(CType.double.isArithmetic)
        XCTAssertFalse(CType.pointer(to: .int).isArithmetic)
    }

    func testIsScalar() {
        XCTAssertTrue(CType.int.isScalar)
        XCTAssertTrue(CType.pointer(to: .int).isScalar)
        XCTAssertFalse(CType.array(of: .int, count: 5).isScalar)
    }

    func testIsPointer() {
        XCTAssertTrue(CType.pointer(to: .int).isPointer)
        XCTAssertFalse(CType.int.isPointer)
    }

    func testIsSigned() {
        XCTAssertTrue(CType.int.isSigned)
        XCTAssertTrue(CType.char.isSigned)
        XCTAssertFalse(CType.uint.isSigned)
        XCTAssertFalse(CType.bool.isSigned)
    }

    // MARK: - Sizes and alignment (ARM64 LP64)

    func testSizes() {
        XCTAssertEqual(CType.bool.sizeInBytes, 1)
        XCTAssertEqual(CType.char.sizeInBytes, 1)
        XCTAssertEqual(CType.short.sizeInBytes, 2)
        XCTAssertEqual(CType.int.sizeInBytes, 4)
        XCTAssertEqual(CType.long.sizeInBytes, 8)
        XCTAssertEqual(CType.longLong.sizeInBytes, 8)
        XCTAssertEqual(CType.float.sizeInBytes, 4)  // float is 4 bytes
        XCTAssertEqual(CType.double.sizeInBytes, 8)
        XCTAssertEqual(CType.pointer(to: .int).sizeInBytes, 8)
    }

    func testAlignment() {
        XCTAssertEqual(CType.char.alignOf, 1)
        XCTAssertEqual(CType.short.alignOf, 2)
        XCTAssertEqual(CType.int.alignOf, 4)
        XCTAssertEqual(CType.long.alignOf, 8)
        XCTAssertEqual(CType.double.alignOf, 8)
        XCTAssertEqual(CType.pointer(to: .int).alignOf, 8)
    }

    // MARK: - Record and enum types

    func testStructType() {
        let rec = RecordType(name: "Point", fields: [
            RecordField(name: "x", type: .int, offset: 0),
            RecordField(name: "y", type: .int, offset: 4),
        ], size: 8, alignment: 4)
        let ty = CType.structType(rec)
        XCTAssertTrue(ty.isStruct)
        XCTAssertEqual(ty.sizeInBytes, 8)
        XCTAssertEqual(ty.alignOf, 4)
    }

    func testUnionType() {
        let rec = RecordType(name: "U", fields: [
            RecordField(name: "i", type: .int, offset: 0),
            RecordField(name: "d", type: .double, offset: 0),
        ], size: 8, alignment: 8)
        let ty = CType.unionType(rec)
        XCTAssertTrue(ty.isUnion)
    }

    func testEnumType() {
        let en = EnumType(name: "Color", cases: [
            EnumCase(name: "RED", value: 0),
            EnumCase(name: "GREEN", value: 1),
            EnumCase(name: "BLUE", value: 2),
        ])
        let ty = CType.enumType(en)
        XCTAssertTrue(ty.isEnum)
        XCTAssertEqual(ty.sizeInBytes, 4)
    }
}
